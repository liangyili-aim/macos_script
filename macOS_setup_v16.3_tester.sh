#!/bin/zsh

# ==========================================
# macOS セットアップスクリプト v16 - テスター版
# ==========================================
#
# 機能：
# 1. コンピュータ名とローカルホスト名の設定
# 2. 管理者ユーザーの作成とSecureToken設定
# 3. FileVault の有効化と復旧キーの保存
# 4. SMBサーバからのログアップロード・ソフトウェアダウンロード
#
# 特徴：
# - 管理者パスワード事前設定による完全自動化
# - plist方式によるFileVault確実有効化
# - セキュアなパスワード処理とクリーンアップ
# - 5回のパスワード試行機会
#
# === NASダウンロード項目の追加方法 ===
# 新しいダウンロード項目を追加する場合は、DOWNLOAD_ITEMS配列に以下の形式で追記してください：
# "表示名|SMB共有上のパス|説明"
# 
# 例: "Google Chrome|Browsers/ChromeInstaller.dmg|Webブラウザ"
#
# ==========================================

# ==========================================
# 設定変数セクション（維持管理者向け）
# ==========================================

# 新規ユーザー設定
readonly NEW_USER_DEFAULT_PASSWORD="aim20110601"      # 新規管理者ユーザーのデフォルトパスワード
readonly NEW_USER_DEFAULT_SHELL="/bin/zsh"            # 新規ユーザーのデフォルトシェル

# SMBサーバー設定
readonly SMB_SERVER="nas.aiming.local"                # SMBサーバーアドレス
readonly SMB_USER="aiming"                             # SMBユーザー名
readonly SMB_DEFAULT_SHARE="INFRA-SETUP"              # デフォルトSMB共有名
readonly SMB_DEFAULT_UPLOAD_PATH="macOS_filevault_key_backup"  # ログアップロード先パス

# ログファイル設定
readonly LOG_FILE_PERMISSIONS=600                     # ログファイルの権限

# システム設定
readonly COMPUTER_NAME_MAX_LENGTH=63                  # コンピュータ名最大文字数
readonly USERNAME_MAX_LENGTH=31                       # ユーザー名最大文字数

# SMBマウント設定
readonly SMB_MOUNT_MAX_ATTEMPTS=3                     # SMBマウント最大試行回数
readonly SMB_UNMOUNT_WAIT_SECONDS=3                   # アンマウント前待機秒数

# 自動化設定（デフォルト有効）
readonly AUTO_SETUP_ENABLED=true                      # 管理者パスワード自動設定を強制有効

# デバッグ設定（開発者向け - 詳細出力表示）
readonly DEBUG_MODE=false                             # true: 詳細出力表示, false: 通常動作

# 予約されたユーザー名リスト
readonly RESERVED_USERNAMES=("root" "admin" "administrator" "daemon" "nobody" "www" "mysql" "postgres")

# ダウンロード対象ファイル設定
readonly DOWNLOAD_ITEMS=(
    "Symantec SEP Cloud版|Symantec/SEP Cloud版 オンラインインストーラー 14.3 RU9(Tokyo_Mac)/Install Symantec Endpoint Protection.app|ウイルス対策ソフト"
    "Microsoft 365 & Office|Software/Microsoft_365_and_Office_16.87.24071426_BusinessPro_Installer.pkg|Office スイート"
)

# ==========================================
# システム設定とグローバル変数
# ==========================================

# エラー時即座に終了
set -uo pipefail

# ロケール設定
export LC_ALL=ja_JP.UTF-8

# グローバル変数
TMP_FULL_LOG_FILE=""
TEMP_PLIST_FILE=""
LOCAL_TEMP_MOUNT_POINT=""
ACTUAL_COMPUTER_NAME_FOR_LOGS=""
RECOVERY_KEY_ONLY_LOG_FILE=""
FULL_SESSION_LOG_FILE=""
ADMIN_PASSWORD_INPUT=""
STORED_ADMIN_PASSWORD=""
USE_STORED_PASSWORD=false

# 一時ファイル作成
TMP_FULL_LOG_FILE=$(mktemp)

# ==========================================
# クリーンアップとセキュリティ
# ==========================================

cleanup() {
    local exit_code=$?
    
    # 機密情報を含む変数をクリア
    unset ADMIN_PASSWORD_INPUT 2>/dev/null || true
    unset STORED_ADMIN_PASSWORD 2>/dev/null || true
    
    # 一時ファイルのクリーンアップ
    [[ -n "${TMP_FULL_LOG_FILE:-}" && -f "${TMP_FULL_LOG_FILE}" ]] && rm -f "$TMP_FULL_LOG_FILE"
    [[ -n "${TEMP_PLIST_FILE:-}" && -f "${TEMP_PLIST_FILE}" ]] && rm -f "$TEMP_PLIST_FILE"
    
    # 一時マウントポイントのクリーンアップ
    if [[ -n "${LOCAL_TEMP_MOUNT_POINT:-}" && -d "${LOCAL_TEMP_MOUNT_POINT}" ]]; then
        echo "緊急クリーンアップ: 一時マウントポイントのアンマウント..."
        diskutil unmount force "$LOCAL_TEMP_MOUNT_POINT" 2>/dev/null || true
        rmdir "$LOCAL_TEMP_MOUNT_POINT" 2>/dev/null || true
    fi
    
    exit $exit_code
}
trap cleanup EXIT INT TERM

# ==========================================
# ユーティリティ関数
# ==========================================

# 自動化対応sudo実行
execute_sudo() {
    local command="$1"
    local description="${2:-sudo操作}"
    
    if [[ "$USE_STORED_PASSWORD" == true ]]; then
        if [[ "$DEBUG_MODE" == true ]]; then
            echo "🐛 DEBUG: ${description}を実行中..."
            echo "🐛 DEBUG: 実行コマンド: $command"
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S sh -c "$command"
            local sudo_result=$?
            echo "🐛 DEBUG: コマンド終了コード: $sudo_result"
        else
            echo "🤖 自動化: ${description}を実行中..."
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S sh -c "$command" 2>/dev/null
            local sudo_result=$?
        fi
        
        if [ $sudo_result -eq 0 ]; then
            return 0
        else
            echo "⚠️ 自動化でのsudo実行に失敗しました。"
            echo "❌ パスワードエラーまたは権限不足のため処理を中止します。"
            exit 1
        fi
    else
        echo "❌ パスワードが設定されていないため、${description}を実行できません。"
        echo "スクリプトを再実行してください。"
        exit 1
    fi
}

# コンピュータ名検証
validate_computer_name() {
    local name="$1"
    [[ -n "$name" && ! "$name" =~ ^[[:space:]]*$ && ${#name} -le $COMPUTER_NAME_MAX_LENGTH ]]
}

# ユーザー名検証
validate_username() {
    local username="$1"
    
    # 基本フォーマットチェック
    if [[ -z "$username" || ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo "⚠️ ユーザー名は英字で始まり、英数字、ハイフン、アンダースコアのみ使用可能です。"
        return 1
    fi
    
    # 長さチェック
    if [[ ${#username} -gt $USERNAME_MAX_LENGTH ]]; then
        echo "⚠️ ユーザー名は${USERNAME_MAX_LENGTH}文字以下である必要があります。"
        return 1
    fi
    
    # 予約語チェック
    local reserved
    for reserved in "${RESERVED_USERNAMES[@]}"; do
        if [[ "$username" == "$reserved" ]]; then
            echo "⚠️ '$username' は予約されたユーザー名です。"
            return 1
        fi
    done
    
    return 0
}

# ==========================================
# 自動Adminパスワード入力セットアップ（デフォルト有効）
# ==========================================

setup_automation() {
    echo "🤖 自動設定（v16テスター版）"
    echo "---------------------------------------------------------------------"
    echo "管理者パスワード事前設定による、以下の操作を自動化にします："
    # echo "以下の操作を自動化します："
    echo "  • sudo操作（コンピュータ名設定、ユーザー作成など）"
    echo "  • FileVault有効化（plist方式）"
    echo "  • SecureToken設定"
    # echo ""
    # echo "⚠️  セキュリティ保証："
    # echo "  • パスワードはメモリ内でのみ保持、ログ記録なし"
    # echo "  • スクリプト終了時に自動的にクリア"
    echo "---------------------------------------------------------------------"
    
    local current_admin_user="${SUDO_USER:-$(whoami)}"
    local attempt=1
    local max_attempts=5
    
    while [[ $attempt -le $max_attempts ]]; do
        echo ""
        if [[ $attempt -eq 1 ]]; then
            printf "管理者 %s のパスワードを入力してください: " "$current_admin_user"
        else
            printf "管理者 %s のパスワードを再入力してください (試行 %d/%d): " "$current_admin_user" "$attempt" "$max_attempts"
        fi
        
        read -s STORED_ADMIN_PASSWORD
        echo ""
        
        # パスワードが空の場合も無効として扱う
        if [[ -z "$STORED_ADMIN_PASSWORD" ]]; then
            echo "❌ パスワードが入力されませんでした。"
        else
            # パスワードの有効性を検証
            echo "パスワードの有効性を検証中..."
            if printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S true 2>/dev/null; then
                echo "✅ パスワードが確認されました。自動化を有効にします。"
                USE_STORED_PASSWORD=true
                ADMIN_PASSWORD_INPUT="$STORED_ADMIN_PASSWORD"
                break
            else
                echo "❌ パスワードが無効です。"
            fi
        fi
        
        # 最大試行回数に達した場合
        if [[ $attempt -eq $max_attempts ]]; then
            echo ""
            echo "❌ ${max_attempts}回の試行に失敗しました。"
            echo "パスワードの入力に失敗したため、スクリプトを終了します。"
            echo ""
            echo "💡 解決方法："
            echo "  1. 管理者パスワードを確認してください"
            echo "  2. 正しいパスワードでスクリプトを再実行してください"
            echo "  3. 実行コマンド: ./$(basename "$0")"
            echo ""
            exit 1
        fi
        
        ((attempt++))
    done
    
    echo "---------------------------------------------------------------------"
    echo ""
}

# ==========================================
# コンピュータ名設定
# ==========================================

setup_computer_name() {
    echo "🖥️  コンピュータ名とローカルホスト名の設定"
    echo "---------------------------------------------------------------------"
    
    local new_computer_name=""
    
    while true; do
        read -p "新しいコンピュータ名を入力してください (Enterでスキップ): " new_computer_name
        
        if [[ -z "$new_computer_name" ]]; then
            echo "コンピュータ名の設定をスキップします。"
            return 0
        fi
        
        if validate_computer_name "$new_computer_name"; then
            break
        else
            echo "⚠️ 無効なコンピュータ名です（最大${COMPUTER_NAME_MAX_LENGTH}文字）。再度入力してください。"
        fi
    done

    echo ""
    echo "設定名:"
    echo "  コンピュータ名: $new_computer_name"
    echo "  ローカルホスト名: $new_computer_name"

    read -p "設定しますか？ [Y/n]: " confirm_input
    if [[ "${confirm_input:-Y}" =~ ^[Yy]$ ]]; then
        execute_sudo "scutil --set ComputerName '$new_computer_name'" "コンピュータ名設定"
        execute_sudo "scutil --set LocalHostName '$new_computer_name'" "ローカルホスト名設定"
        
        echo "✅ 設定完了"
        ACTUAL_COMPUTER_NAME_FOR_LOGS="$new_computer_name"
        echo "  コンピュータ名: $(scutil --get ComputerName)"
        echo "  ローカルホスト名: $(scutil --get LocalHostName)"
    else
        echo "設定をキャンセルしました。"
    fi
}

# ==========================================
# 管理者ユーザー作成
# ==========================================

create_admin_user() {
    local current_admin_user="${SUDO_USER:-$(whoami)}"
    
    echo "👤 新しい管理者ユーザーアカウントの作成"
    echo "---------------------------------------------------------------------"
    
    read -p "新しい管理者ユーザーを作成しますか？ [Y/n]: " create_admin_input
    if [[ ! "${create_admin_input:-Y}" =~ ^[Yy]$ ]]; then
        echo "ユーザー作成をスキップしました。"
        return 0
    fi

    local new_admin_name=""
    while true; do
        read -p "新しい管理者名（例: kaishaadmin）: " new_admin_name
        
        if validate_username "$new_admin_name"; then
            break
        fi
    done

    # ユーザー存在チェック
    if dscl . -read "/Users/$new_admin_name" >/dev/null 2>&1; then
        echo "⚠️ ユーザー「${new_admin_name}」は既に存在します。作成を中止します。"
        return 1
    fi

    echo "ユーザー「${new_admin_name}」を作成します。"

    # ユーザー作成
    local create_command="sysadminctl -addUser "$new_admin_name" -fullName "$new_admin_name" -shell "$NEW_USER_DEFAULT_SHELL" -password "$NEW_USER_DEFAULT_PASSWORD" -admin"
    
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "🐛 DEBUG: ユーザー作成コマンド実行"
        echo "🐛 DEBUG: $create_command"
        printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S eval "$create_command"
        local create_result=$?
        echo "🐛 DEBUG: ユーザー作成終了コード: $create_result"
    else
        execute_sudo "$create_command" "ユーザー作成"
        local create_result=$?
    fi
    
    if [ $create_result -eq 0 ]; then
        echo "✅ ユーザー作成成功"
        
        # SecureToken設定
        echo "SecureTokenを設定中..."
        local secure_token_cmd="sysadminctl -adminUser "$current_admin_user" -adminPassword "$STORED_ADMIN_PASSWORD" -secureTokenOn "$new_admin_name" -password "$NEW_USER_DEFAULT_PASSWORD""

        if [[ "$DEBUG_MODE" == true ]]; then
            echo "🐛 DEBUG: SecureToken設定コマンド実行"
            # パスワード部分をマスクして表示
            local masked_cmd="sysadminctl -adminUser "$current_admin_user" -adminPassword "***MASKED***" -secureTokenOn "$new_admin_name" -password "***MASKED***""
            echo "🐛 DEBUG: $masked_cmd"
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S eval "$secure_token_cmd"
            local token_result=$?
            echo "🐛 DEBUG: SecureToken設定終了コード: $token_result"
        else
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S eval "$secure_token_cmd" 2>/dev/null
            local token_result=$?
        fi
        
        if [ $token_result -eq 0 ]; then
            echo "✅ SecureToken設定成功"
        else
            echo "⚠️ SecureToken設定失敗"
        fi
        
        # パスワード変更要求設定
        if execute_sudo "pwpolicy -u $new_admin_name -setpolicy 'newPasswordRequired=1'" "パスワード変更要求設定"; then
            echo "✅ 次回ログイン時パスワード変更要求設定完了"
        fi
        
        echo "✅ 管理者ユーザー「${new_admin_name}」の作成完了"
    else
        echo "⚠️ ユーザー作成失敗"
        return 1
    fi
}

# ==========================================
# ログファイル設定
# ==========================================

setup_log_files() {
    # コンピュータ名の取得
    if [[ -z "$ACTUAL_COMPUTER_NAME_FOR_LOGS" ]]; then
        ACTUAL_COMPUTER_NAME_FOR_LOGS=$(scutil --get ComputerName 2>/dev/null || echo "UnknownMac")
    fi

    # ファイル名用にサニタイズ
    local sanitized_name
    sanitized_name=$(echo "$ACTUAL_COMPUTER_NAME_FOR_LOGS" | sed 's/ /_/g' | sed 's/[^a-zA-Z0-9_-]//g')
    [[ -z "$sanitized_name" ]] && sanitized_name="UnnamedMac"

    # ログファイル名生成
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    RECOVERY_KEY_ONLY_LOG_FILE="$HOME/${sanitized_name}_FileVault_RecoveryKey_${timestamp}.txt"
    FULL_SESSION_LOG_FILE="$HOME/${sanitized_name}_FileVault_FullSession_${timestamp}.txt"

    # ログファイル作成と権限設定
    touch "$RECOVERY_KEY_ONLY_LOG_FILE" "$FULL_SESSION_LOG_FILE"
    chmod $LOG_FILE_PERMISSIONS "$RECOVERY_KEY_ONLY_LOG_FILE" "$FULL_SESSION_LOG_FILE"

    echo "📄 ログファイル設定"
    echo "---------------------------------------------------------------------"
    echo "復旧キー専用: $RECOVERY_KEY_ONLY_LOG_FILE"
    echo "完全セッション: $FULL_SESSION_LOG_FILE"
    echo "---------------------------------------------------------------------"
}

# ==========================================
# FileVault処理
# ==========================================

handle_filevault() {
    echo "🔒 FileVault 処理"
    echo "---------------------------------------------------------------------"
    
    # FileVault状態確認
    local fv_status
    fv_status=$(printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S fdesetup status 2>/dev/null)
    echo "現在の状態: $fv_status"

    if [[ "$fv_status" == *"FileVault is On."* ]]; then
        echo "✅ FileVaultは既に有効です。処理をスキップします。"
        create_skip_log "$fv_status"
        return 0
    fi

    if [[ "$fv_status" == *"FileVault is Off."* ]]; then
        echo "ℹ️ FileVaultを有効化します。"
        enable_filevault
    else
        read -p "FileVault状態が不明です。有効化を試みますか？ [Y/n]: " try_anyway
        if [[ "${try_anyway:-Y}" =~ ^[Yy]$ ]]; then
            enable_filevault
        else
            create_skip_log "$fv_status"
        fi
    fi
}

enable_filevault() {
    local current_admin_user="${SUDO_USER:-$(whoami)}"
    
    echo ""
    echo "🚀 FileVault 有効化開始"
    echo "⚠️  重要: 復旧キーを必ず安全な場所に保管してください"
    echo ""
    
    read -p "FileVault有効化を開始しますか？ [Y/n]: " fv_enable_input
    local enable_choice="${fv_enable_input:-Y}"

    if [[ "$enable_choice" =~ ^[Yy]$ ]]; then
        echo "plistファイルを使用してFileVaultを有効化中..."
        
        # plistファイル作成
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
        
        # FileVault有効化実行
        if [[ "$DEBUG_MODE" == true ]]; then
            echo "🐛 DEBUG: FileVault有効化開始（plist方式）"
            echo "🐛 DEBUG: 使用ユーザー: $current_admin_user"
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S fdesetup enable -inputplist < "$TEMP_PLIST_FILE" 2>&1 | tee "$TMP_FULL_LOG_FILE"
            local fv_result=${PIPESTATUS[1]}
            echo "🐛 DEBUG: FileVault有効化終了コード: $fv_result"
        else
            printf '%s\n' "$STORED_ADMIN_PASSWORD" | sudo -S fdesetup enable -inputplist < "$TEMP_PLIST_FILE" 2>&1 | tee "$TMP_FULL_LOG_FILE"
            local fv_result=${PIPESTATUS[1]}
        fi
        
        if [ $fv_result -eq 0 ]; then
            echo "✅ FileVault有効化成功"
        else
            echo "⚠️ FileVault有効化失敗"
        fi
        
        # plistファイルクリーンアップ
        [[ -f "$TEMP_PLIST_FILE" ]] && rm -f "$TEMP_PLIST_FILE"
        TEMP_PLIST_FILE=""
        
        # ログファイル保存
        cp "$TMP_FULL_LOG_FILE" "$FULL_SESSION_LOG_FILE"
        echo "📄 完全ログ保存: $FULL_SESSION_LOG_FILE"
        
        extract_recovery_key
    else
        echo "FileVault有効化をキャンセルしました。"
        create_cancel_log
    fi
}

extract_recovery_key() {
    echo "🔑 復旧キー抽出中..."
    
    local recovery_key_line
    recovery_key_line=$(grep -iE 'Recovery =|Recovery' "$TMP_FULL_LOG_FILE" 2>/dev/null || echo "")
    
    if [[ -n "$recovery_key_line" ]]; then
        local extracted_key
        extracted_key=$(echo "$recovery_key_line" | grep -oE '([A-Z0-9]{4}-){5}[A-Z0-9]{4}' || echo "")
        
        if [[ -n "$extracted_key" ]]; then
            echo "$extracted_key" > "$RECOVERY_KEY_ONLY_LOG_FILE"
            echo "🔑 復旧キー保存: $RECOVERY_KEY_ONLY_LOG_FILE"
            echo "内容: $extracted_key"
            echo "🚨 重要: この復旧キーを安全な場所に保管してください"
        else
            echo "$recovery_key_line" > "$RECOVERY_KEY_ONLY_LOG_FILE"
            echo "⚠️ 復旧キー形式抽出失敗、関連情報を保存しました"
        fi
    else
        echo "⚠️ 復旧キーが見つかりませんでした" > "$RECOVERY_KEY_ONLY_LOG_FILE"
    fi
}

create_skip_log() {
    local fv_status="$1"
    {
        echo "FileVault有効化プロセスはスキップされました。"
        echo "理由: FileVaultは既に有効であるか、ユーザーがスキップを選択"
        echo "現在のFileVaultステータス: $fv_status"
    } > "$FULL_SESSION_LOG_FILE"
    
    echo "FileVault有効化がスキップされたため、新しい復旧キーはありません。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
}

create_cancel_log() {
    echo "FileVault有効化はユーザーによりキャンセルされました。" > "$FULL_SESSION_LOG_FILE"
    echo "FileVault有効化がキャンセルされたため、新しい復旧キーはありません。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
}

# ==========================================
# SMB操作
# ==========================================

handle_smb_operations() {
    echo "📤📂 SMBサーバ操作"
    echo "---------------------------------------------------------------------"
    echo "ログアップロード・ソフトウェアダウンロード機能"
    echo "サーバ: $SMB_SERVER"
    echo "ユーザ: $SMB_USER"
    echo "共有: $SMB_DEFAULT_SHARE"
    echo ""
    
    read -p "ログファイルをSMBサーバにアップロードしますか？ [Y/n]: " upload_input
    local perform_upload="${upload_input:-Y}"

    read -p "共通インストーラーをSMBサーバからダウンロードしますか？ [Y/n]: " download_input
    local perform_download="${download_input:-Y}"

    local upload_requested=false
    local download_requested=false
    
    [[ "$perform_upload" =~ ^[Yy]$ ]] && upload_requested=true
    [[ "$perform_download" =~ ^[Yy]$ ]] && download_requested=true

    if [[ "$upload_requested" == true || "$download_requested" == true ]]; then
        setup_smb_connection "$upload_requested" "$download_requested"
    else
        echo "SMB操作をスキップしました。"
    fi
}

setup_smb_connection() {
    local upload_requested="$1"
    local download_requested="$2"
    
    # echo ""
    # echo "SMBサーバ接続情報:"
    # echo "  サーバ: $SMB_SERVER"
    # echo "  ユーザ: $SMB_USER"
    # echo ""

    read -p "SMB共有名を入力してください [${SMB_DEFAULT_SHARE}]: " input_share
    local smb_share="${input_share:-$SMB_DEFAULT_SHARE}"
    
    if [[ -z "$smb_share" ]]; then
        echo "⚠️ SMB共有名が指定されなかったため、SMB操作を中止します。"
        return 1
    fi

    local smb_url="//${SMB_USER}@${SMB_SERVER}/${smb_share}"
    local standard_mount="/Volumes/${smb_share}"
    local final_target=""
    local use_temp_mount=true
    
    # 既存マウントのチェック
    if mount | grep -qE "^${smb_url} on ${standard_mount} \\(smbfs"; then
        if [[ -d "$standard_mount" ]]; then
            echo "✅ 既存マウント (${standard_mount}) を使用します。"
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
        echo "⚠️ 一時マウントポイントの作成に失敗: $LOCAL_TEMP_MOUNT_POINT"
        return 1
    fi
    
    # SMBマウントの試行
    local attempt=1
    
    while [[ $attempt -le $SMB_MOUNT_MAX_ATTEMPTS ]]; do
        if [[ "$DEBUG_MODE" == true ]]; then
            echo "🐛 DEBUG: SMBマウント試行 ($attempt/$SMB_MOUNT_MAX_ATTEMPTS)"
            echo "🐛 DEBUG: マウントポイント: $LOCAL_TEMP_MOUNT_POINT"
            echo "🐛 DEBUG: マウントURL: $mount_url"
            mount_smbfs "$mount_url" "$LOCAL_TEMP_MOUNT_POINT"
            local mount_result=$?
            echo "🐛 DEBUG: マウント終了コード: $mount_result"
        else
            echo "SMB共有のマウント試行 ($attempt/$SMB_MOUNT_MAX_ATTEMPTS)..."
            echo "  マウントポイント: $LOCAL_TEMP_MOUNT_POINT"
            echo "  マウントURL: $mount_url"
            mount_smbfs "$mount_url" "$LOCAL_TEMP_MOUNT_POINT"
            local mount_result=$?
        fi
        
        if [ $mount_result -eq 0 ]; then
            echo "✅ SMB共有の一時マウント成功"
            return 0
        else
            echo "⚠️ SMB共有の一時マウント失敗 (試行 $attempt/$SMB_MOUNT_MAX_ATTEMPTS)"
            
            if [[ $attempt -eq $SMB_MOUNT_MAX_ATTEMPTS ]]; then
                echo "⚠️ 最大試行回数に達しました。SMBマウントを中止します。"
                rmdir "$LOCAL_TEMP_MOUNT_POINT" 2>/dev/null || true
                LOCAL_TEMP_MOUNT_POINT=""
                return 1
            fi
            
            read -p "再試行しますか？ [Y/n]: " retry_input
            if [[ ! "${retry_input:-Y}" =~ ^[Yy]$ ]]; then
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
    echo "--- ログファイルアップロード開始 ---"
    
    read -p "ログ保存先ディレクトリパス (共有 '${share_name}' 内) [${SMB_DEFAULT_UPLOAD_PATH}]: " input_path
    local upload_path="${input_path:-$SMB_DEFAULT_UPLOAD_PATH}"
    
    # パスのクリーンアップ
    upload_path=$(echo "$upload_path" | sed 's#^/*##' | sed 's#/*$##')
    
    local base_upload_dir="$target_base"
    if [[ -n "$upload_path" ]]; then
        base_upload_dir="${target_base}/${upload_path}"
    fi
    
    # 各ログタイプ用のサブディレクトリを作成
    local fullsession_dir="${base_upload_dir}/FullSession"
    local recoverykey_dir="${base_upload_dir}/RecoveryKey"
    
    echo "ログアップロード先:"
    echo "  完全セッションログ: ${fullsession_dir}"
    echo "  復旧キーログ: ${recoverykey_dir}"
    
    # ディレクトリの作成
    if ! mkdir -p "$fullsession_dir"; then
        echo "⚠️ 完全セッションログディレクトリの作成に失敗: ${fullsession_dir}"
        return 1
    fi
    
    if ! mkdir -p "$recoverykey_dir"; then
        echo "⚠️ 復旧キーログディレクトリの作成に失敗: ${recoverykey_dir}"
        return 1
    fi
    
    # ファイルのアップロード（それぞれ専用のサブディレクトリに）
    upload_single_file "$FULL_SESSION_LOG_FILE" "$fullsession_dir" "完全セッションログ"
    upload_single_file "$RECOVERY_KEY_ONLY_LOG_FILE" "$recoverykey_dir" "復旧キーログ"
    
    echo "--- ログファイルアップロード終了 ---"
}

upload_single_file() {
    local file_path="$1"
    local target_dir="$2"
    local description="$3"
    
    if [[ -f "$file_path" ]]; then
        echo "rsyncで${description}をアップロード中..."
        
        if rsync -ah --progress "$file_path" "$target_dir/"; then
            echo "✅ ${description}のアップロード成功"
        else
            echo "⚠️ ${description}のアップロード失敗"
        fi
    else
        echo "⚠️ ${description}ファイルが見つかりません: '$file_path'"
    fi
    echo ""
}

download_from_smb() {
    local target_base="$1"
    
    echo ""
    echo "--- 共通インストーラーダウンロード開始 ---"
    
    # デスクトップパスの決定
    local user_desktop
    user_desktop=$(get_user_desktop_path)
    
    if [[ ! -d "$user_desktop" ]]; then
        echo "⚠️ ダウンロード先デスクトップが見つかりません。処理を中止します。"
        return 1
    fi
    
    echo "ダウンロード先: $user_desktop"
    echo ""
    
    # ダウンロード項目の選択と実行
    select_and_download_items "$target_base" "$user_desktop"
    
    echo "--- 共通インストーラーダウンロード終了 ---"
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
    
    local selected_items=()
    local item_index=0
    
    # 各アイテムの確認
    for item in "${DOWNLOAD_ITEMS[@]}"; do
        ((item_index++))
        
        IFS='|' read -r display_name smb_path description <<< "$item"
        local file_name
        file_name=$(basename "$smb_path")
        
        echo "ダウンロード候補 ${item_index}: ${display_name}"
        echo "  ファイル名: ${file_name}"
        echo "  説明: ${description}"
        echo "  SMB共有上のパス: ${smb_path}"
        
        read -p "このアイテムをデスクトップにダウンロードしますか？ [Y/n]: " confirm_input
        if [[ "${confirm_input:-Y}" =~ ^[Yy]$ ]]; then
            selected_items+=("$item")
        fi
        echo ""
    done
    
    # ダウンロード実行
    if [[ ${#selected_items[@]} -eq 0 ]]; then
        echo "すべてのアイテムがスキップされました。"
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
        
        echo "--- 「${display_name}」ダウンロード実行 ---"
        echo "ファイル名: ${file_name}"
        echo "rsyncでコピー中..."
        
        if [[ -e "$source_full_path" ]]; then
            if rsync -ah --progress "$source_full_path" "$dest_desktop/"; then
                echo "✅ 「${display_name}」ダウンロード成功"
                ((downloads_succeeded++))
            else
                echo "⚠️ 「${display_name}」ダウンロード失敗"
            fi
        else
            echo "⚠️ ファイルが見つかりません: \"$source_full_path\""
        fi
        echo ""
    done
    
    # ダウンロード結果サマリー
    echo "=== ダウンロード結果 ==="
    if [[ $downloads_succeeded -gt 0 ]]; then
        echo "✅ ${downloads_succeeded}件のダウンロード完了"
    fi
    if [[ $downloads_succeeded -lt $downloads_attempted ]]; then
        echo "⚠️ $((downloads_attempted - downloads_succeeded))件のダウンロード失敗"
    fi
}

cleanup_temp_mount() {
    if [[ -z "$LOCAL_TEMP_MOUNT_POINT" || ! -d "$LOCAL_TEMP_MOUNT_POINT" ]]; then
        return 0
    fi
    
    echo ""
    echo "ℹ️ アンマウント前の待機 (${SMB_UNMOUNT_WAIT_SECONDS}秒)..."
    sleep $SMB_UNMOUNT_WAIT_SECONDS
    
    echo "一時SMB共有 ($LOCAL_TEMP_MOUNT_POINT) をアンマウント中..."
    
    # 通常のアンマウント試行
    if diskutil unmount "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1; then
        echo "✅ 一時SMB共有アンマウント成功 (通常)"
    else
        echo "⚠️ 通常のアンマウント失敗。強制アンマウント試行..."
        
        if diskutil unmount force "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1; then
            echo "✅ 一時SMB共有アンマウント成功 (強制)"
        else
            echo "⚠️ 強制アンマウントも失敗。手動対応が必要な場合があります。"
            echo "   コマンド例: sudo diskutil unmount force \"$LOCAL_TEMP_MOUNT_POINT\""
        fi
    fi
    
    # 一時ディレクトリの削除
    if rmdir "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1; then
        echo "✅ 一時マウントポイントディレクトリを削除"
    else
        echo "ℹ️ 一時マウントポイントディレクトリの削除に失敗。手動確認が必要な場合があります。"
    fi
    
    LOCAL_TEMP_MOUNT_POINT=""
}

# ==========================================
# メイン実行関数
# ==========================================

main() {
    echo "🚀 macOS セットアップスクリプト v16 (テスター版) 開始"
    echo "============================================"
    
    # デバッグモード表示
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "🐛 DEBUG MODE ENABLED - 詳細出力表示"
        echo "============================================"
    fi
    
    echo ""
    
    # 自動化設定（強制有効）
    setup_automation
    
    # 各処理の実行
    echo ""
    setup_computer_name
    echo ""
    create_admin_user
    echo ""
    setup_log_files
    echo ""
    handle_filevault
    echo ""
    handle_smb_operations
    
    echo ""
    echo "============================================"
    echo "🚨 重要: FileVault復旧キーを安全な場所に保管してください"
    echo "============================================"
    echo "✅ スクリプト完了"
    echo ""
    echo "🤖 パスワードは自動的にクリアされます"
}

# ==========================================
# スクリプト実行
# ==========================================

main "$@"
exit 0
