#!/bin/zsh

# macOS セットアップスクリプト v15 - 安定版（外部依存なし）
# 
# このスクリプトは以下の機能を提供します：
# 1. コンピュータ名の設定
# 2. FileVault の有効化と復旧キーの保存
# 3. 管理者ユーザーの作成（事前に管理者パスワードを設定可能）
# 4. SMBサーバからの共通ソフトウェアのダウンロード
#
# === 外部依存なし ===
# このバージョンはmacOS標準コマンドのみを使用します。
# expect、brew、その他の外部ツールは一切不要です。
# macOSの初期セットアップ直後に実行可能です。
#
# === 自動化機能 ===
# 管理者パスワードを事前に設定することで、sudo操作を自動化できます。
# セキュリティ上の理由により、パスワードはスクリプト実行時に入力し、
# メモリ内でのみ保持されます。
#
# ==========================================

# エラー時即座に終了（ただし、main関数内では個別にハンドリング）
set -uo pipefail

# スクリプト終了時のクリーンアップ処理
cleanup() {
    local exit_code=$?
    
    # 機密情報を含む可能性のある変数をクリア
    unset ADMIN_PASSWORD_INPUT 2>/dev/null || true
    unset NEW_USER_PASSWORD 2>/dev/null || true
    unset STORED_ADMIN_PASSWORD 2>/dev/null || true
    
    # 一時ファイルのクリーンアップ
    if [[ -n "${TMP_FULL_LOG_FILE:-}" && -f "${TMP_FULL_LOG_FILE}" ]]; then
        rm -f "$TMP_FULL_LOG_FILE"
    fi
    
    # 一時plistファイルのクリーンアップ
    if [[ -n "${TEMP_PLIST_FILE:-}" && -f "${TEMP_PLIST_FILE}" ]]; then
        rm -f "$TEMP_PLIST_FILE"
    fi
    
    # 一時マウントポイントのクリーンアップ
    if [[ -n "${LOCAL_TEMP_MOUNT_POINT:-}" && -d "${LOCAL_TEMP_MOUNT_POINT}" ]]; then
        echo "緊急クリーンアップ: 一時マウントポイントのアンマウントを試みます..."
        diskutil unmount force "$LOCAL_TEMP_MOUNT_POINT" 2>/dev/null || true
        rmdir "$LOCAL_TEMP_MOUNT_POINT" 2>/dev/null || true
    fi
    
    exit $exit_code
}
trap cleanup EXIT INT TERM

# スクリプト全体のロケールを日本語UTF-8に設定 (文字化け対策)
export LC_ALL=ja_JP.UTF-8

# グローバル変数の初期化
TMP_FULL_LOG_FILE=""
TEMP_PLIST_FILE=""
LOCAL_TEMP_MOUNT_POINT=""
ACTUAL_COMPUTER_NAME_FOR_LOGS=""
RECOVERY_KEY_ONLY_LOG_FILE=""
FULL_SESSION_LOG_FILE=""
ADMIN_PASSWORD_INPUT=""
NEW_USER_PASSWORD="aim20110601"
STORED_ADMIN_PASSWORD=""
USE_STORED_PASSWORD=false

# 一時ファイル作成
TMP_FULL_LOG_FILE=$(mktemp)

# 自動化のための管理者パスワード設定
setup_automation() {
    echo "🤖 自動化設定 (外部依存なし)"
    echo "---------------------------------------------------------------------"
    echo "管理者パスワードを事前に設定することで、以下の操作を自動化できます："
    echo "  • sudo操作（コンピュータ名設定、ユーザー作成など）"
    echo "  • FileVault有効化（plist方式で確実に自動化）"
    echo "  • SecureToken設定"
    echo ""
    echo "⚠️  セキュリティに関する重要な注意："
    echo "  • パスワードはメモリ内でのみ保持され、ログに記録されません"
    echo "  • スクリプト終了時に自動的にクリアされます"
    echo "  • 外部ツール（expect等）は使用せず、macOS標準機能のみ使用"
    echo ""
    
    read -p "管理者パスワードを事前に設定して自動化しますか？ [Y/n]: " automation_choice
    local user_choice="${automation_choice:-Y}"
    
    if [[ "$user_choice" =~ ^[Yy]$ ]]; then
        local current_admin_user="${SUDO_USER:-$(whoami)}"
        echo ""
        printf "管理者 %s のパスワードを入力してください: " "$current_admin_user"
        read -s STORED_ADMIN_PASSWORD
        echo ""
        
        if [[ -n "$STORED_ADMIN_PASSWORD" ]]; then
            # パスワードの検証（外部依存なし）
            echo "パスワードの有効性を検証中..."
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S true 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "✅ パスワードが確認されました。自動化を有効にします。"
                USE_STORED_PASSWORD=true
                ADMIN_PASSWORD_INPUT="$STORED_ADMIN_PASSWORD"
            else
                echo "⚠️ パスワードが無効です。自動化は無効のまま、各操作時に個別入力します。"
                unset STORED_ADMIN_PASSWORD
                USE_STORED_PASSWORD=false
            fi
        else
            echo "⚠️ パスワードが入力されませんでした。自動化は無効のまま続行します。"
            USE_STORED_PASSWORD=false
        fi
    else
        echo "自動化を無効にします。各操作時に個別にパスワードを入力してください。"
        USE_STORED_PASSWORD=false
    fi
    
    echo "---------------------------------------------------------------------"
    echo ""
}

# 自動化対応のsudo実行関数（外部依存なし）
execute_sudo() {
    local command="$1"
    local description="${2:-sudo操作}"
    
    if [[ "$USE_STORED_PASSWORD" == true ]]; then
        echo "🤖 自動化: ${description}を実行中..."
        printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S sh -c "$command" 2>/dev/null
        if [ $? -eq 0 ]; then
            return 0
        else
            echo "⚠️ 自動化でのsudo実行に失敗しました。手動入力に切り替えます。"
            USE_STORED_PASSWORD=false
            sudo sh -c "$command"
        fi
    else
        echo "手動入力: ${description}のためにパスワードを入力してください。"
        sudo sh -c "$command"
    fi
}

# 入力検証関数
validate_computer_name() {
    local name="$1"
    if [[ -z "$name" || "$name" =~ ^[[:space:]]*$ ]]; then
        return 1
    fi
    if [[ ${#name} -gt 63 ]]; then
        echo "⚠️ コンピュータ名は63文字以下である必要があります。"
        return 1
    fi
    return 0
}

validate_username() {
    local username="$1"
    if [[ -z "$username" || ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo "⚠️ ユーザー名は英字で始まり、英数字、ハイフン、アンダースコアのみ使用可能です。"
        return 1
    fi
    if [[ ${#username} -gt 31 ]]; then
        echo "⚠️ ユーザー名は31文字以下である必要があります。"
        return 1
    fi
    local reserved_names=("root" "admin" "administrator" "daemon" "nobody" "www" "mysql" "postgres")
    for reserved in "${reserved_names[@]}"; do
        if [[ "$username" == "$reserved" ]]; then
            echo "⚠️ '$username' は予約されたユーザー名です。"
            return 1
        fi
    done
    return 0
}

# --- コンピュータ名とローカルホスト名の設定 ---
setup_computer_name() {
    echo "---------------------------------------------------------------------"
    echo "🖥️  コンピュータ名とローカルホスト名の設定"
    echo "---------------------------------------------------------------------"
    
    local new_computer_name=""
    
    while true; do
        read -p "新しいコンピュータ名を入力してください (例: 私のMacBookPro、空白でスキップ): " new_computer_name
        
        if [[ -z "$new_computer_name" ]]; then
            echo "コンピュータ名の設定をスキップします。現在の名前を維持します。"
            return 0
        fi
        
        if validate_computer_name "$new_computer_name"; then
            break
        else
            echo "⚠️ 無効なコンピュータ名です。再度入力してください。"
        fi
    done

    if [[ -n "$new_computer_name" ]]; then
        echo ""
        echo "以下の名前で設定します:"
        echo "  コンピュータ名 (ComputerName): $new_computer_name"
        echo "  ローカルホスト名 (LocalHostName): $new_computer_name"

        read -p "よろしいですか？ [Y/n]: " confirm_input
        local user_choice="${confirm_input:-Y}"

        if [[ "$user_choice" =~ ^[Yy]$ ]]; then
            echo ""
            execute_sudo "scutil --set ComputerName '$new_computer_name'" "コンピュータ名設定"
            execute_sudo "scutil --set LocalHostName '$new_computer_name'" "ローカルホスト名設定"
            echo ""
            echo "✅ コンピュータ名とローカルホスト名が設定されました。"
            ACTUAL_COMPUTER_NAME_FOR_LOGS="$new_computer_name"
            echo "現在の設定:"
            echo "  コンピュータ名: $(scutil --get ComputerName)"
            echo "  ローカルホスト名: $(scutil --get LocalHostName)"
        else
            echo "コンピュータ名とローカルホスト名の設定はキャンセルされました。"
        fi
    fi
}

# --- 新しい管理者ユーザーの追加 ---
create_admin_user() {
    local current_admin_user="${SUDO_USER:-$(whoami)}"
    echo ""
    echo "---------------------------------------------------------------------"
    echo "👤 新しい管理者ユーザーアカウントの作成"
    echo "---------------------------------------------------------------------"
    
    read -p "新しい管理者ユーザーを作成しますか？ [Y/n]: " create_admin_input
    local user_choice="${create_admin_input:-Y}"
    
    if [[ ! "$user_choice" =~ ^[Yy]$ ]]; then
        echo "新しい管理者ユーザーの作成はスキップされました。"
        return 0
    fi

    # 自動化が無効の場合のみパスワード入力を求める
    if [[ "$USE_STORED_PASSWORD" != true ]]; then
        echo ""
        printf "管理者 %s のパスワードを入力してください: " "$current_admin_user"
        read -s ADMIN_PASSWORD_INPUT
        echo ""
        
        if [[ -z "$ADMIN_PASSWORD_INPUT" ]]; then
            echo "⚠️ 管理者パスワードが入力されませんでした。ユーザー作成を中止します。"
            return 1
        fi
    else
        echo "🤖 自動化: 事前設定されたパスワードを使用します。"
    fi

    local new_admin_name=""
    while true; do
        read -p "新しい管理者の名前（ログイン名およびフルネームとして使用、例: kaishaadmin）: " new_admin_name
        
        if validate_username "$new_admin_name"; then
            break
        else
            echo "再度入力してください。"
        fi
    done

    if [[ -z "$new_admin_name" ]]; then
        echo "⚠️ 名前が入力されませんでした。ユーザー作成を中止します。"
        return 1
    fi

    local new_admin_shortname="$new_admin_name"
    local new_admin_fullname="$new_admin_name"

    # ユーザー存在チェック
    if dscl . -read "/Users/$new_admin_shortname" >/dev/null 2>&1; then
        echo "⚠️ ユーザー「${new_admin_shortname}」は既に存在します。作成を中止します。"
        return 1
    fi

    echo "ユーザー「${new_admin_shortname}」（フルネーム:「${new_admin_fullname}」）を作成します。"

    # ユーザー作成の実行
    local create_command="sysadminctl -addUser '$new_admin_shortname' -fullName '$new_admin_fullname' -shell '/bin/zsh' -password '$NEW_USER_PASSWORD' -admin"
    
    echo "  sysadminctlを使用してユーザーレコードを作成中..."
    if execute_sudo "$create_command" "ユーザー作成"; then
        echo "  ✅ sysadminctlによるユーザー作成に成功しました。"
        echo "  (ユーザー、ホームディレクトリ、管理者権限がすべて設定されました)"
        
        # SecureToken設定（外部依存なしバージョン）
        echo "  SecureTokenを設定中..."
        if [[ "$USE_STORED_PASSWORD" == true ]]; then
            # 自動化モード：標準入力でパスワードを渡す
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S sysadminctl -adminUser "$current_admin_user" -adminPassword "$STORED_ADMIN_PASSWORD" -secureTokenOn "$new_admin_shortname" -password "$NEW_USER_PASSWORD" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "  ✅ ユーザー「${new_admin_shortname}」にSecureTokenが正常に設定されました。"
            else
                echo "  ⚠️ ユーザー「${new_admin_shortname}」のSecureToken設定に失敗しました。"
            fi
        else
            # 手動モード：通常のsudo実行
            if execute_sudo "sysadminctl -adminUser '$current_admin_user' -adminPassword '$ADMIN_PASSWORD_INPUT' -secureTokenOn '$new_admin_shortname' -password '$NEW_USER_PASSWORD'" "SecureToken設定"; then
                echo "  ✅ ユーザー「${new_admin_shortname}」にSecureTokenが正常に設定されました。"
            else
                echo "  ⚠️ ユーザー「${new_admin_shortname}」のSecureToken設定に失敗しました。"
            fi
        fi
        
        # パスワード変更要求設定
        local pwpolicy_command="pwpolicy -u '$new_admin_shortname' -setpolicy 'newPasswordRequired=1'"
        
        if execute_sudo "$pwpolicy_command" "パスワード変更要求設定"; then
            echo "  ✅ 次回ログイン時のパスワード変更要求が設定されました。"
        else
            echo "  ⚠️ 次回ログイン時のパスワード変更要求の設定に失敗しました。"
        fi
        
        echo "✅ 新しい管理者ユーザー「${new_admin_shortname}」の作成が完了しました。"
    else
        echo "⚠️ sysadminctlによるユーザー作成に失敗しました。"
        return 1
    fi
    
    return 0
}

# ログファイル設定
setup_log_files() {
    if [[ -z "$ACTUAL_COMPUTER_NAME_FOR_LOGS" ]]; then
        local current_system_computer_name
        current_system_computer_name=$(scutil --get ComputerName 2>/dev/null || echo "")
        if [[ -n "$current_system_computer_name" ]]; then
            ACTUAL_COMPUTER_NAME_FOR_LOGS="$current_system_computer_name"
        else
            ACTUAL_COMPUTER_NAME_FOR_LOGS="UnknownMac"
        fi
    fi

    local sanitized_name
    sanitized_name=$(echo "$ACTUAL_COMPUTER_NAME_FOR_LOGS" | sed 's/ /_/g' | sed 's/[^a-zA-Z0-9_-]//g')
    if [[ -z "$sanitized_name" ]]; then
        sanitized_name="UnnamedMac"
    fi

    RECOVERY_KEY_ONLY_LOG_FILE="$HOME/${sanitized_name}_FileVault_RecoveryKey_$(date +"%Y%m%d_%H%M%S").txt"
    FULL_SESSION_LOG_FILE="$HOME/${sanitized_name}_FileVault_FullSession_$(date +"%Y%m%d_%H%M%S").txt"

    touch "$RECOVERY_KEY_ONLY_LOG_FILE" "$FULL_SESSION_LOG_FILE"
    chmod 600 "$RECOVERY_KEY_ONLY_LOG_FILE" "$FULL_SESSION_LOG_FILE"

    echo "---------------------------------------------------------------------"
    echo "ログファイルは以下の名前で保存されます:"
    echo "  復旧キー専用ログ: $RECOVERY_KEY_ONLY_LOG_FILE"
    echo "  完全セッションログ: $FULL_SESSION_LOG_FILE"
    echo "---------------------------------------------------------------------"
    echo ""
}

# FileVault処理（外部依存なし - 安定版）
handle_filevault() {
    echo "🔒 FileVault の状態を確認します..."
    local fv_status
    if [[ "$USE_STORED_PASSWORD" == true ]]; then
        fv_status=$(printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S fdesetup status 2>/dev/null || sudo fdesetup status)
    else
        fv_status=$(sudo fdesetup status)
    fi
    echo "現在のFileVaultステータス: $fv_status"

    local perform_fv_enablement=false
    local current_admin_user="${SUDO_USER:-$(whoami)}"

    if [[ "$fv_status" == *"FileVault is On."* ]]; then
        echo "✅ FileVaultは既に有効です。FileVault有効化プロセスはスキップします。"
        perform_fv_enablement=false
    elif [[ "$fv_status" == *"FileVault is Off."* ]]; then
        echo "ℹ️ FileVaultは現在無効です。有効化プロセスに進みます。"
        perform_fv_enablement=true
    else
        echo "⚠️ FileVaultのステータスを明確に判断できませんでした。"
        read -p "このままFileVault有効化プロセスを試みますか？ [Y/n]: " try_anyway
        local user_choice="${try_anyway:-Y}"
        if [[ "$user_choice" =~ ^[Yy]$ ]]; then
            echo "ユーザーの選択により、FileVault有効化プロセスを試みます。"
            perform_fv_enablement=true
        else
            echo "FileVault有効化プロセスはスキップします。"
            perform_fv_enablement=false
        fi
    fi

    if [[ "$perform_fv_enablement" == true ]]; then
        enable_filevault "$current_admin_user"
    else
        create_skip_log "$fv_status"
    fi
}

enable_filevault() {
    local current_admin_user="$1"
    
    echo ""
    echo "FileVault 有効化プロセスを開始します..."
    echo "⚠️  警告: このスクリプトはお使いの Mac で FileVault (フルディスク暗号化) を開始します。"
    
    if [[ "$USE_STORED_PASSWORD" == true ]]; then
        echo "🤖 自動化: 事前設定されたパスワードを使用してFileVaultを有効化します。"
    else
        echo "    macOS の管理者パスワードの入力が求められます。"
    fi
    
    echo ""
    echo "🚨  重要: プロセス中に個人用復旧キーが表示されます。"
    echo "    >> このキーを必ず画面で確認し、書き留め、非常に安全な場所に保管してください。 <<"
    echo "    パスワードとこの復旧キーの両方を紛失すると、データは永久に失われます。"
    echo ""
    echo "🕒  暗号化プロセスにはかなりの時間がかかる場合があります。"
    echo ""
    echo "📄  プロセス全体のやり取りは一時的に記録され、その後、復旧キーの抽出が試みられます。"
    
    read -p "➡️  FileVault有効化に進むには Enter キーを押してください。中止する場合は Ctrl+C を押してください: " -r

    if [[ "$REPLY" == "" ]]; then
        echo ""
        echo "🚀 FileVault の有効化を試みます（安定版）。"
        echo "完全なセッションは一時的に '$TMP_FULL_LOG_FILE' に記録しています..."
        echo ""
        
        # FileVault有効化実行（安定版）
        local filevault_result=0
        if [[ "$USE_STORED_PASSWORD" == true ]]; then
            echo "🤖 自動化モード: plistファイルを使用してFileVaultを有効化します..."
            
            # plistファイルを作成
            TEMP_PLIST_FILE=$(mktemp)
            cat > "$TEMP_PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Username</key>
    <string>$current_admin_user</string>
    <key>Password</key>
    <string>$STORED_ADMIN_PASSWORD</string>
    <key>AdditionalUsers</key>
    <array/>
</dict>
</plist>
EOF
            
            echo "plistファイルを使用してFileVaultを有効化中..."
            if printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S fdesetup enable -inputplist < "$TEMP_PLIST_FILE" 2>&1 | tee "$TMP_FULL_LOG_FILE"; then
                filevault_result=0
                echo "✅ 自動化でのFileVault有効化に成功しました。"
            else
                filevault_result=1
                echo "⚠️ 自動化でのFileVault有効化に失敗しました。手動入力に切り替えます。"
                USE_STORED_PASSWORD=false
                script -q "$TMP_FULL_LOG_FILE" sudo fdesetup enable -u "$current_admin_user"
                filevault_result=$?
            fi
            
            # plistファイルをクリーンアップ
            [[ -f "$TEMP_PLIST_FILE" ]] && rm -f "$TEMP_PLIST_FILE"
            TEMP_PLIST_FILE=""
        else
            # 手動モード：scriptを使用
            echo "手動モードでFileVaultを有効化します。パスワード入力が必要です。"
            script -q "$TMP_FULL_LOG_FILE" sudo fdesetup enable -u "$current_admin_user"
            filevault_result=$?
        fi
        
        echo ""
        echo "✅ FileVault 有効化コマンドの対話部分が完了しました。"
        echo "---------------------------------------------------------------------"
        
        cp "$TMP_FULL_LOG_FILE" "$FULL_SESSION_LOG_FILE"
        echo "📄 'sudo fdesetup enable' コマンドの完全な記録は以下に保存されています:"
        echo "   $FULL_SESSION_LOG_FILE"
        echo ""
        
        extract_recovery_key
    else
        echo "FileVault有効化はユーザーによりキャンセルされました。"
        create_cancel_log
    fi
    
    [[ -f "$TMP_FULL_LOG_FILE" ]] && rm -f "$TMP_FULL_LOG_FILE"
}

extract_recovery_key() {
    echo "🔑 完全ログから復旧キーの抽出を試みています..."
    local recovery_key_line
    recovery_key_line=$(grep -iE 'Recovery =|Recovery' "$TMP_FULL_LOG_FILE" 2>/dev/null || echo "")
    
    if [[ -n "$recovery_key_line" ]]; then
        local extracted_key
        extracted_key=$(echo "$recovery_key_line" | grep -oE '([A-Z0-9]{4}-){5}[A-Z0-9]{4}' || echo "")
        
        if [[ -n "$extracted_key" ]]; then
            echo "$extracted_key" > "$RECOVERY_KEY_ONLY_LOG_FILE"
            echo "🔑 抽出された復旧キーが以下に保存されました:"
            echo "   $RECOVERY_KEY_ONLY_LOG_FILE"
            echo "   内容: $extracted_key"
            echo "🚨 重要: この抽出されたキーが正しいことを、画面に表示されたキーまたは上記の完全なログファイルで必ず確認してください。"
        else
            echo "$recovery_key_line" > "$RECOVERY_KEY_ONLY_LOG_FILE"
            echo "⚠️ 復旧キーの正確な形式での抽出はできませんでしたが、関連する情報を保存しました:"
            echo "   $RECOVERY_KEY_ONLY_LOG_FILE"
        fi
    else
        echo "⚠️ ログから復旧キーが見つかりませんでした。完全なログファイルを確認してください。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
    fi
}

create_skip_log() {
    local fv_status="$1"
    echo "FileVault有効化プロセスはスキップされました。" > "$FULL_SESSION_LOG_FILE"
    echo "理由: FileVaultは既に有効であるか、ユーザーがスキップを選択しました。" >> "$FULL_SESSION_LOG_FILE"
    echo "現在のFileVaultステータス: $fv_status" >> "$FULL_SESSION_LOG_FILE"
    echo "FileVault有効化がスキップされたため、新しい復旧キーはありません。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
}

create_cancel_log() {
    echo "FileVault有効化はユーザーによりキャンセルされました。" > "$FULL_SESSION_LOG_FILE"
    echo "FileVault有効化がキャンセルされたため、新しい復旧キーはありません。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
}

# SMB操作（簡略版）
# SMB操作の改善
handle_smb_operations() {
    echo ""
    echo "---------------------------------------------------------------------"
    echo "📤📂 SMBサーバへのファイル操作 (ログアップロード/インストーラーダウンロード)"
    echo "---------------------------------------------------------------------"

    read -p "ログファイルをSMBサーバ (nas.aiming.local) にアップロードしますか？ [Y/n]: " upload_input
    local perform_upload="${upload_input:-Y}"

    read -p "共通インストーラー等をSMBサーバからデスクトップにダウンロードしますか？ [Y/n]: " download_input
    local perform_download="${download_input:-Y}"

    local upload_requested=false
    local download_requested=false
    
    [[ "$perform_upload" =~ ^[Yy]$ ]] && upload_requested=true
    [[ "$perform_download" =~ ^[Yy]$ ]] && download_requested=true

    if [[ "$upload_requested" == true || "$download_requested" == true ]]; then
        setup_smb_connection "$upload_requested" "$download_requested"
    else
        echo "SMBサーバへのファイル操作（アップロード・ダウンロード）はスキップされました。"
    fi
}

setup_smb_connection() {
    local upload_requested="$1"
    local download_requested="$2"
    
    local smb_server="nas.aiming.local"
    local smb_user="aiming"
    local default_share="INFRA-SETUP"
    
    echo ""
    echo "SMBサーバの情報:"
    echo "  サーバアドレス: $smb_server"
    echo "  ユーザー名: $smb_user"
    echo ""

    read -p "接続するSMB共有名を入力してください（デフォルトは [${default_share}]）: " input_share
    local smb_share="${input_share:-$default_share}"
    
    if [[ -z "$smb_share" ]]; then
        echo "⚠️ SMB共有名が指定されなかったため、SMB操作を中止します。"
        return 1
    fi

    local smb_url="//${smb_user}@${smb_server}/${smb_share}"
    local standard_mount="/Volumes/${smb_share}"
    local final_target=""
    local use_temp_mount=true
    
    # 既存マウントのチェック
    if mount | grep -qE "^${smb_url} on ${standard_mount} \\(smbfs"; then
        if [[ -d "$standard_mount" ]]; then
            echo "✅ 標準GUIマウントポイント (${standard_mount}) が既に存在し、アクティブです。これを使用します。"
            final_target="$standard_mount"
            use_temp_mount=false
        fi
    fi
    
    if [[ "$use_temp_mount" == true ]]; then
        if ! setup_temp_mount "$smb_url"; then
            echo "⚠️ SMB接続に失敗しました。"
            return 1
        fi
        final_target="$LOCAL_TEMP_MOUNT_POINT"
    fi

    # SMB操作の実行
    if [[ -n "$final_target" ]]; then
        [[ "$upload_requested" == true ]] && upload_logs_to_smb "$final_target" "$smb_share"
        [[ "$download_requested" == true ]] && download_from_smb "$final_target"
        
        # クリーンアップ
        [[ "$use_temp_mount" == true ]] && cleanup_temp_mount
    fi
}

setup_temp_mount() {
    local mount_url="$1"
    
    LOCAL_TEMP_MOUNT_POINT="/tmp/smb_ops_mount_$$_$(date +%s)"
    
    # マウントポイントの作成
    if ! mkdir -p "$LOCAL_TEMP_MOUNT_POINT"; then
        echo "⚠️ 一時マウントポイントの作成に失敗しました: $LOCAL_TEMP_MOUNT_POINT"
        return 1
    fi
    
    # SMBマウントの試行
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        echo "SMB共有のマウントを試みます (試行 $attempt/$max_attempts)..."
        echo "  マウントポイント: $LOCAL_TEMP_MOUNT_POINT"
        echo "  マウントURL: $mount_url"
        
        if mount_smbfs "$mount_url" "$LOCAL_TEMP_MOUNT_POINT"; then
            echo "✅ SMB共有の一時マウントに成功しました。"
            return 0
        else
            echo "⚠️ SMB共有の一時マウントに失敗しました (試行 $attempt/$max_attempts)。"
            
            if [[ $attempt -eq $max_attempts ]]; then
                echo "⚠️ 最大試行回数に達しました。SMBマウントを中止します。"
                rmdir "$LOCAL_TEMP_MOUNT_POINT" 2>/dev/null || true
                LOCAL_TEMP_MOUNT_POINT=""
                return 1
            fi
            
            read -p "再試行しますか？ [Y/n]: " retry_input
            local retry_choice="${retry_input:-Y}"
            
            if [[ ! "$retry_choice" =~ ^[Yy]$ ]]; then
                echo "SMBマウントをキャンセルしました。"
                rmdir "$LOCAL_TEMP_MOUNT_POINT" 2>/dev/null || true
                LOCAL_TEMP_MOUNT_POINT=""
                return 1
            fi
            
            ((attempt++))
        fi
    done
    
    return 1
}

upload_logs_to_smb() {
    local target_base="$1"
    local share_name="$2"
    
    echo ""
    echo "--- ログファイルのアップロード開始 ---"
    local default_upload_path="macOS_filevault_key_backup"
    
    read -p "ログの保存先ディレクトリパス (共有 '${share_name}' 内) を入力してください [$default_upload_path]: " input_path
    local upload_path="${input_path:-$default_upload_path}"
    
    # パスのクリーンアップ
    upload_path=$(echo "$upload_path" | sed 's#^/*##' | sed 's#/*$##')
    
    local final_upload_dir="$target_base"
    if [[ -n "$upload_path" ]]; then
        final_upload_dir="${target_base}/${upload_path}"
    fi
    
    echo "ログアップロード先ディレクトリ: ${final_upload_dir}"
    
    if ! mkdir -p "$final_upload_dir"; then
        echo "⚠️ ログアップロード先ディレクトリの作成に失敗しました: ${final_upload_dir}"
        return 1
    fi
    
    # ファイルのアップロード
    upload_single_file "$FULL_SESSION_LOG_FILE" "$final_upload_dir" "完全セッションログ"
    upload_single_file "$RECOVERY_KEY_ONLY_LOG_FILE" "$final_upload_dir" "復旧キーログ"
    
    echo "--- ログファイルのアップロード終了 ---"
}

upload_single_file() {
    local file_path="$1"
    local target_dir="$2"
    local description="$3"
    
    if [[ -f "$file_path" ]]; then
        echo "rsync を使用して${description} '$file_path' をアップロード中 (進捗表示あり)..."
        
        if rsync -ah --progress "$file_path" "$target_dir/"; then
            echo "✅ ${description}のアップロードに成功しました。"
        else
            echo "⚠️ ${description}のアップロードに失敗しました。"
        fi
    else
        echo "⚠️ ${description}ファイル '$file_path' が見つからないため、アップロードをスキップします。"
    fi
    echo ""
}

download_from_smb() {
    local target_base="$1"
    
    echo ""
    echo "--- 共通インストーラーのダウンロード確認 ---"
    
    # デスクトップパスの決定
    local user_desktop
    user_desktop=$(get_user_desktop_path)
    
    if [[ ! -d "$user_desktop" ]]; then
        echo "⚠️ ダウンロード先デスクトップフォルダが見つかりません。ダウンロード処理を中止します。"
        return 1
    fi
    
    echo "ダウンロード先デスクトップ: $user_desktop"
    echo ""
    
    # ダウンロード項目の選択と実行を直接実行
    select_and_download_items "$target_base" "$user_desktop"
    
    echo ""
    echo "--- 共通インストーラーのダウンロード処理終了 ---"
}

get_user_desktop_path() {
    local logged_in_user
    logged_in_user=$(stat -f%Su /dev/console 2>/dev/null || echo "")
    
    if [[ -n "$logged_in_user" && "$logged_in_user" != "root" ]]; then
        local user_home
        user_home=$(dscl . -read "/Users/$logged_in_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || echo "")
        if [[ -d "$user_home/Desktop" ]]; then
            echo "$user_home/Desktop"
            return 0
        fi
    fi
    
    # フォールバック
    if [[ -d "$HOME/Desktop" ]]; then
        echo "$HOME/Desktop"
    else
        echo ""
    fi
}

select_and_download_items() {
    local source_base="$1"
    local dest_desktop="$2"
    
    # ダウンロード対象ファイルの設定（直接ここで定義）
    local download_items=(
        "Symantec SEP Cloud版|Symantec/SEP Cloud版 オンラインインストーラー 14.3 RU9(Tokyo_Mac)/Install Symantec Endpoint Protection.app|ウイルス対策ソフト"
        "Microsoft 365 & Office|Software/Microsoft_365_and_Office_16.87.24071426_BusinessPro_Installer.pkg|Office スイート"
        "テストファイル|Setup動画/Readme.txt|テストテストファイル"
    )
    
    local selected_items=()
    local item_index=0
    
    # 各アイテムの確認
    for item in "${download_items[@]}"; do
        ((item_index++))
        
        IFS='|' read -r display_name smb_path description <<< "$item"
        local file_name
        file_name=$(basename "$smb_path")
        
        echo "ダウンロード候補 ${item_index}: ${display_name}"
        echo "  ファイル名: ${file_name}"
        echo "  説明: ${description}"
        echo "  (SMB共有上のパス: ${smb_path})"
        
        read -p "このアイテムをデスクトップにダウンロードしますか？ [Y/n]: " confirm_input
        if [[ "${confirm_input:-Y}" =~ ^[Yy]$ ]]; then
            selected_items+=("$item")
        fi
        echo ""
    done
    
    # ダウンロード実行
    if [[ ${#selected_items[@]} -eq 0 ]]; then
        echo "すべてのアイテムがスキップされたため、ダウンロードは実行されませんでした。"
        return 0
    fi
    
    echo "選択されたアイテムをダウンロードします..."
    echo ""
    
    local downloads_attempted=0
    local downloads_succeeded=0
    
    for selected_item in "${selected_items[@]}"; do
        ((downloads_attempted++))
        
        IFS='|' read -r display_name smb_path description <<< "$selected_item"
        local file_name
        file_name=$(basename "$smb_path")
        local source_full_path="${source_base}/${smb_path}"
        
        echo "--- 「${display_name}」のダウンロード処理実行 ---"
        echo "ファイル名: ${file_name}"
        echo "rsync を使用してコピー中 (進捗表示あり)..."
        
        if [[ -e "$source_full_path" ]]; then
            if rsync -ah --progress "$source_full_path" "$dest_desktop/"; then
                echo "✅ 「${display_name}」のダウンロードに成功しました。"
                ((downloads_succeeded++))
            else
                echo "⚠️ 「${display_name}」のダウンロードに失敗しました。"
            fi
        else
            echo "⚠️ ファイル「${file_name}」が見つかりません: \"$source_full_path\""
        fi
        echo ""
    done
    
    # ダウンロード結果サマリー
    echo "=== ダウンロード結果サマリー ==="
    if [[ $downloads_succeeded -gt 0 ]]; then
        echo "✅ ${downloads_succeeded}件のアイテムのダウンロードが完了しました。"
    fi
    if [[ $downloads_succeeded -lt $downloads_attempted ]]; then
        echo "⚠️ $((downloads_attempted - downloads_succeeded))件のアイテムはダウンロードに失敗したか、見つかりませんでした。"
    fi
}

cleanup_temp_mount() {
    if [[ -z "$LOCAL_TEMP_MOUNT_POINT" || ! -d "$LOCAL_TEMP_MOUNT_POINT" ]]; then
        return 0
    fi
    
    echo ""
    echo "ℹ️ アンマウント前にシステムがファイル操作を完了するための待機時間を設けます (3秒)..."
    sleep 3
    
    echo "一時SMB共有 ($LOCAL_TEMP_MOUNT_POINT) のアンマウントを試みます..."
    
    # 通常のアンマウント試行
    if diskutil unmount "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1; then
        echo "✅ 一時SMB共有のアンマウントに成功しました (通常)。"
    else
        echo "⚠️ 通常のアンマウントに失敗しました。強制アンマウントを試みます..."
        
        if diskutil unmount force "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1; then
            echo "✅ 一時SMB共有のアンマウントに成功しました (強制)。"
        else
            echo "⚠️ 強制アンマウントにも失敗しました。手動でアンマウントが必要な場合があります。"
            echo "   試行コマンド例: sudo diskutil unmount force \"$LOCAL_TEMP_MOUNT_POINT\""
        fi
    fi
    
    # 一時ディレクトリの削除
    if rmdir "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1; then
        echo "✅ 一時マウントポイントディレクトリを削除しました。"
    else
        echo "ℹ️ 一時マウントポイントディレクトリの削除に失敗しました。手動での確認が必要な場合があります。"
    fi
    
    LOCAL_TEMP_MOUNT_POINT=""
}

# 依存関係チェック（外部依存なしバージョン）
check_dependencies() {
    echo "✅ 外部依存関係なしモード: macOS標準コマンドのみを使用します。"
    echo "   このスクリプトは以下のコマンドのみを使用します："
    echo "   • sudo, scutil, sysadminctl, fdesetup, dscl, pwpolicy"
    echo "   • script, grep, sed, date, mktemp, touch, chmod"
    echo "   • printf, tee, cp, rm, diskutil"
    echo "   これらはすべてmacOSに標準で含まれています。"
    echo ""
    return 0
}

# メイン実行関数
main() {
    echo "🚀 macOS セットアップスクリプト v15 (安定版・外部依存なし) を開始します..."
    echo ""
    
    # 自動化設定
    setup_automation
    
    # 各処理の実行
    setup_computer_name || echo "⚠️ コンピュータ名設定でエラーが発生しましたが、処理を続行します。"
    echo "---------------------------------------------------------------------"
    echo ""
    
    create_admin_user || echo "⚠️ 管理者ユーザー作成でエラーが発生しましたが、処理を続行します。"
    echo "---------------------------------------------------------------------"
    echo ""
    
    setup_log_files || echo "⚠️ ログファイル設定でエラーが発生しましたが、処理を続行します。"
    
    handle_filevault || echo "⚠️ FileVault処理でエラーが発生しましたが、処理を続行します。"
    
    handle_smb_operations || echo "⚠️ SMB操作でエラーが発生しましたが、処理を続行します。"
    
    echo ""
    echo "---------------------------------------------------------------------"
    echo "🚨🚨 再確認: 画面に表示された、または完全ログに記録された個人用復旧キーを、"
    echo "   安全な場所に確実に保管したことを確認してください！ 🚨🚨"
    echo "---------------------------------------------------------------------"
    echo ""
    echo "✅ スクリプトが正常に完了しました（安定版・外部依存なし）。"
    
    if [[ "$USE_STORED_PASSWORD" == true ]]; then
        echo ""
        echo "🤖 自動化が使用されました。セキュリティのため、保存されたパスワードは自動的にクリアされます。"
    fi
}

# スクリプト実行
echo "🔍 依存関係をチェック中..."
check_dependencies

echo "DEBUG: main関数を開始します..."
main "$@"
echo "DEBUG: main関数が完了しました。"
echo "DEBUG: スクリプトを終了します。"
exit 0
