#!/bin/zsh
# スクリプト全体のロケールを日本語UTF-8に設定 (文字化け対策)
export LC_ALL=ja_JP.UTF-8
TMP_FULL_LOG_FILE=$(mktemp) # 一時ファイルは最初に作成
NEW_USER_PASSWORD="aim20110601" 
SMB_SERVER="10.1.51.251"; SMB_USER="aiming"; DEFAULT_SMB_SHARE_NAME="INFRA"

# --- コンピュータ名とローカルホスト名の設定 ---
echo "---------------------------------------------------------------------"
echo "🖥️  まず、コンピュータ名とローカルホスト名を設定します。"
echo "---------------------------------------------------------------------"
read -p "新しいコンピュータ名を入力してください (例: 私のMacBookPro): " NEW_COMPUTER_NAME_INPUT

ACTUAL_COMPUTER_NAME_FOR_LOGS=""
CONFIRM_HOSTNAME_CHANGE="n" 

if [ -n "$NEW_COMPUTER_NAME_INPUT" ]; then
    echo ""
    echo "以下の名前で設定します:"
    echo "  コンピュータ名 (ComputerName): $NEW_COMPUTER_NAME_INPUT"
    echo "  ローカルホスト名 (LocalHostName): $NEW_COMPUTER_NAME_INPUT"

    read -p "よろしいですか？ [Y/n]: " CONFIRM_HOSTNAME_CHANGE_INPUT 
    USER_CHOICE_HOSTNAME_CONFIRMATION="${CONFIRM_HOSTNAME_CHANGE_INPUT:-Y}"

    if [[ "$USER_CHOICE_HOSTNAME_CONFIRMATION" =~ ^[Yy]$ ]]; then
        CONFIRM_HOSTNAME_CHANGE="y" 
        echo ""
        echo "コンピュータ名を設定中..."
        sudo scutil --set ComputerName "$NEW_COMPUTER_NAME_INPUT"
        echo "ローカルホスト名を設定中..."
        sudo scutil --set LocalHostName "$NEW_COMPUTER_NAME_INPUT"
        echo ""
        echo "✅ コンピュータ名とローカルホスト名が設定されました。"
        ACTUAL_COMPUTER_NAME_FOR_LOGS="$NEW_COMPUTER_NAME_INPUT"
        echo "現在の設定:"
        echo "  コンピュータ名: $(scutil --get ComputerName)"
        echo "  ローカルホスト名: $(scutil --get LocalHostName)"
    else
        CONFIRM_HOSTNAME_CHANGE="n"
        echo "コンピュータ名とローカルホスト名の設定はキャンセルされました。"
    fi
else
    echo "コンピュータ名が入力されなかったため、設定をスキップします。"
fi

if [ -z "$ACTUAL_COMPUTER_NAME_FOR_LOGS" ]; then
    CURRENT_SYSTEM_COMPUTER_NAME=$(scutil --get ComputerName)
    if [ -n "$CURRENT_SYSTEM_COMPUTER_NAME" ]; then
        ACTUAL_COMPUTER_NAME_FOR_LOGS="$CURRENT_SYSTEM_COMPUTER_NAME"
    else
        ACTUAL_COMPUTER_NAME_FOR_LOGS="UnknownMac" 
    fi
fi

ACTUAL_COMPUTER_NAME_FOR_LOGS_SANITIZED=$(echo "$ACTUAL_COMPUTER_NAME_FOR_LOGS" | sed 's/ /_/g' | sed 's/[^a-zA-Z0-9_-]//g')
if [ -z "$ACTUAL_COMPUTER_NAME_FOR_LOGS_SANITIZED" ]; then
    ACTUAL_COMPUTER_NAME_FOR_LOGS_SANITIZED="UnnamedMac"
fi

RECOVERY_KEY_ONLY_LOG_FILE="$HOME/${ACTUAL_COMPUTER_NAME_FOR_LOGS_SANITIZED}_FileVault_RecoveryKey_$(date +"%Y%m%d_%H%M%S").txt"
FULL_SESSION_LOG_FILE="$HOME/${ACTUAL_COMPUTER_NAME_FOR_LOGS_SANITIZED}_FileVault_FullSession_$(date +"%Y%m%d_%H%M%S").txt"

# --- 新しい管理者ユーザーの追加 ---
echo ""
echo "---------------------------------------------------------------------"
echo "👤 新しい管理者ユーザーアカウントの作成"
echo "---------------------------------------------------------------------"
read -p "新しい管理者ユーザーを作成しますか？ [Y/n]: " CREATE_NEW_ADMIN_INPUT_VAL 
USER_CHOICE_CREATE_ADMIN="${CREATE_NEW_ADMIN_INPUT_VAL:-Y}" 

if [[ "$USER_CHOICE_CREATE_ADMIN" =~ ^[Yy]$ ]]; then
    echo ""
    read -p "新しい管理者の名前（ログイン名およびフルネームとして使用、例: kaishaadmin）: " NEW_ADMIN_NAME_INPUT 

    if [ -z "$NEW_ADMIN_NAME_INPUT" ]; then
        echo "⚠️ 名前が入力されませんでした。ユーザー作成を中止します。"
    else
        NEW_ADMIN_SHORTNAME="$NEW_ADMIN_NAME_INPUT"
        NEW_ADMIN_FULLNAME="$NEW_ADMIN_NAME_INPUT"

        if dscl . -read "/Users/$NEW_ADMIN_SHORTNAME" > /dev/null 2>&1; then
            echo "⚠️ ユーザー「$NEW_ADMIN_SHORTNAME」は既に存在します。作成を中止します。"
        else
            echo "ユーザー「$NEW_ADMIN_SHORTNAME」（フルネーム:「$NEW_ADMIN_FULLNAME」）を作成します。"

            LAST_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | grep -E '^[0-9]+$' | sort -n | tail -1)
            if [ -z "$LAST_UID" ] || [ "$LAST_UID" -lt 500 ]; then NEW_UID=501; else NEW_UID=$((LAST_UID + 1)); fi
            echo "  新しいユーザーID: $NEW_UID"

            USER_CREATE_SUCCESS=false
            echo "  基本ユーザーレコードを作成中..."
            sudo dscl . -create "/Users/$NEW_ADMIN_SHORTNAME" && \
            sudo dscl . -create "/Users/$NEW_ADMIN_SHORTNAME" UserShell "/bin/zsh" && \
            sudo dscl . -create "/Users/$NEW_ADMIN_SHORTNAME" RealName "$NEW_ADMIN_FULLNAME" && \
            sudo dscl . -create "/Users/$NEW_ADMIN_SHORTNAME" UniqueID "$NEW_UID" && \
            sudo dscl . -create "/Users/$NEW_ADMIN_SHORTNAME" PrimaryGroupID 20 && \
            sudo dscl . -create "/Users/$NEW_ADMIN_SHORTNAME" NFSHomeDirectory "/Users/$NEW_ADMIN_SHORTNAME"
            
            if [ $? -eq 0 ]; then
                echo "  基本ユーザーレコードの作成に成功しました。"
                echo "  ホームディレクトリを作成中 (/Users/$NEW_ADMIN_SHORTNAME)..."
                if [ ! -d "/Users/$NEW_ADMIN_SHORTNAME" ]; then
                    sudo mkdir -p "/Users/$NEW_ADMIN_SHORTNAME"
                    if [ $? -ne 0 ]; then echo "⚠️ ホームディレクトリの作成に失敗(mkdir): /Users/$NEW_ADMIN_SHORTNAME"; else
                        TEMPLATE_PATH="/System/Library/User Template/English.lproj"
                        if [ -d "$TEMPLATE_PATH" ]; then
                             echo "  ユーザテンプレート (${TEMPLATE_PATH}) からファイルをコピー中..."
                             sudo cp -R "${TEMPLATE_PATH}/." "/Users/$NEW_ADMIN_SHORTNAME/"
                             if [ $? -ne 0 ]; then echo "⚠️ ユーザテンプレートのコピーに失敗しました。"; fi
                        else echo "⚠️ ユーザテンプレート (${TEMPLATE_PATH}) が見つかりません。"; fi
                        sudo chown -R "${NEW_ADMIN_SHORTNAME}:staff" "/Users/$NEW_ADMIN_SHORTNAME"
                        if [ $? -ne 0 ]; then echo "⚠️ ホームディレクトリの所有権設定に失敗しました。"; fi
                        echo "  ホームディレクトリの準備ができました。"
                    fi
                else echo "  ホームディレクトリ (/Users/$NEW_ADMIN_SHORTNAME) は既に存在します。"; fi
                
                echo "  定義済みパスワードを設定中..." 
                if sudo dscl . -passwd "/Users/$NEW_ADMIN_SHORTNAME" "$NEW_USER_PASSWORD"; then
                    echo "  定義済みパスワードの設定に成功しました。"
                    echo "  次回ログイン時にパスワード変更を要求するように設定中..."
                    if sudo pwpolicy -u "$NEW_ADMIN_SHORTNAME" -setpolicy "newPasswordRequired=1"; then
                        echo "  ✅ 次回ログイン時のパスワード変更要求が設定されました。"
                        echo "  管理者グループ (admin) に追加中..."
                        if sudo dscl . -append "/Groups/admin" GroupMembership "$NEW_ADMIN_SHORTNAME"; then
                            echo "✅ 新しい管理者ユーザー「${NEW_ADMIN_SHORTNAME}」が正常に作成され、管理者グループに追加されました。"
                            USER_CREATE_SUCCESS=true
                        else echo "⚠️ ユーザー「${NEW_ADMIN_SHORTNAME}」を管理者グループに追加できませんでした。";fi
                    else echo "⚠️ 次回ログイン時のパスワード変更要求の設定に失敗しました。";fi
                else echo "⚠️ 定義済みパスワードの設定に失敗しました。";fi
            else echo "⚠️ 基本ユーザーレコードの作成中にエラーが発生しました。";fi

            if [ "$USER_CREATE_SUCCESS" = false ]; then
                echo "ユーザー「${NEW_ADMIN_SHORTNAME}」の作成プロセス中にエラーが発生したか、一部のステップが完了しませんでした。"
                echo "不完全なユーザーレコードが残っている可能性があります。"
                echo "必要に応じて手動で確認・削除してください: (例: sudo dscl . -delete \"/Users/$NEW_ADMIN_SHORTNAME\")"
            fi
        fi
    fi
else
    echo "新しい管理者ユーザーの作成はスキップされました。"
fi
echo "---------------------------------------------------------------------"
echo ""

# ログファイル名表示ブロック
echo "---------------------------------------------------------------------"
echo "ログファイルは以下の名前で保存されます:"
echo "  復旧キー専用ログ: $RECOVERY_KEY_ONLY_LOG_FILE"
echo "  完全セッションログ: $FULL_SESSION_LOG_FILE"
echo "---------------------------------------------------------------------"
echo ""

# --- FileVaultステータス確認と有効化プロセス ---
echo "🔒 FileVault の状態を確認します..."
FV_STATUS=$(sudo fdesetup status)
echo "現在のFileVaultステータス: $FV_STATUS"

PERFORM_FV_ENABLEMENT=false

if echo "$FV_STATUS" | grep -q "FileVault is On."; then
    echo "✅ FileVaultは既に有効です。FileVault有効化プロセスはスキップします。"
    PERFORM_FV_ENABLEMENT=false
elif echo "$FV_STATUS" | grep -q "FileVault is Off."; then
    echo "ℹ️ FileVaultは現在無効です。有効化プロセスに進みます。"
    PERFORM_FV_ENABLEMENT=true
else
    echo "⚠️ FileVaultのステータスを明確に判断できませんでした ('On' または 'Off' ではありません)。"
    read -p "このままFileVault有効化プロセスを試みますか？ [Y/n]: " TRY_FV_ENABLE_ANYWAY_INPUT
    USER_CHOICE_FV_AMBIGUOUS="${TRY_FV_ENABLE_ANYWAY_INPUT:-Y}" 
    if [[ "$USER_CHOICE_FV_AMBIGUOUS" =~ ^[Yy]$ ]]; then
        echo "ユーザーの選択により、FileVault有効化プロセスを試みます。"
        PERFORM_FV_ENABLEMENT=true
    else
        echo "FileVault有効化プロセスはスキップします。"
        PERFORM_FV_ENABLEMENT=false 
    fi
fi

if [ "$PERFORM_FV_ENABLEMENT" = true ]; then
    echo ""
    echo "FileVault 有効化プロセスを開始します..."
    echo "⚠️  警告: このスクリプトはお使いの Mac で FileVault (フルディスク暗号化) を開始します。"
    echo "    macOS の管理者パスワードの入力が求められます。"
    echo ""
    echo "🚨  重要: プロセス中に個人用復旧キーが表示されます。"
    echo "    >> このキーを必ず画面で確認し、書き留め、非常に安全な場所に保管してください。 <<"
    echo "    パスワードとこの復旧キーの両方を紛失すると、データは永久に失われます。"
    echo ""
    echo "🕒  暗号化プロセスにはかなりの時間がかかる場合があります。"
    echo ""
    echo "📄  プロセス全体のやり取りは一時的に記録され、その後、復旧キーの抽出が試みられます。"
    read -p "➡️  FileVault有効化に進むには Enter キーを押してください。中止する場合は Ctrl+C を押してください: " -r

    USER_WANTS_TO_PROCEED_FV=false
    if [[ "$REPLY" == "" ]]; then
        USER_WANTS_TO_PROCEED_FV=true
    fi

    if [ "$USER_WANTS_TO_PROCEED_FV" = true ]; then
        echo ""
        echo "🚀 FileVault の有効化を試みます。プロンプトに注意して従ってください。"
        echo "完全なセッションは一時的に '$TMP_FULL_LOG_FILE' に記録しています。画面の指示に従ってください..."
        echo ""
        script -q "$TMP_FULL_LOG_FILE" sudo fdesetup enable
        echo ""
        echo "✅ FileVault 有効化コマンドの対話部分が完了しました。"
        echo "---------------------------------------------------------------------"
        cp "$TMP_FULL_LOG_FILE" "$FULL_SESSION_LOG_FILE"
        echo "📄 'sudo fdesetup enable' コマンドの完全な記録は以下に保存されています:"
        echo "   $FULL_SESSION_LOG_FILE"
        echo "   (問題発生時や確認のためにご利用ください)"
        echo ""
        echo "🔑 完全ログから復旧キーの抽出を試みています..."
        RECOVERY_KEY_LINE=$(grep -iE 'Recovery =|Recovery' "$TMP_FULL_LOG_FILE")
        if [ -n "$RECOVERY_KEY_LINE" ]; then
            EXTRACTED_KEY=$(echo "$RECOVERY_KEY_LINE" | grep -oE '([A-Z0-9]{4}-){5}[A-Z0-9]{4}')
            if [ -n "$EXTRACTED_KEY" ]; then
                echo "$EXTRACTED_KEY" > "$RECOVERY_KEY_ONLY_LOG_FILE"
                echo "🔑 抽出された可能性のある復旧キーが以下に保存されました:"
                echo "   $RECOVERY_KEY_ONLY_LOG_FILE"
                echo "   内容: $EXTRACTED_KEY"
                echo "🚨 重要: この抽出されたキーが正しいことを、画面に表示されたキーまたは上記の完全なログファイルで必ず確認してください。"
            else
                echo "$RECOVERY_KEY_LINE" > "$RECOVERY_KEY_ONLY_LOG_FILE"
                echo "⚠️ 復旧キーの正確な形式 (XXXX-XXXX-...) での抽出はできませんでしたが、関連する可能性のある情報を含む行を以下に保存しました:"
                echo "   $RECOVERY_KEY_ONLY_LOG_FILE"
                echo "   完全なログファイル ($FULL_SESSION_LOG_FILE) を確認してください。"
            fi
        else
            echo "⚠️ ログから「Recovery =」または「Recovery」というフレーズを含む行が見つかりませんでした。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
            echo "   FileVault が正常に有効化されなかったか、出力形式が異なる可能性があります。" >> "$RECOVERY_KEY_ONLY_LOG_FILE"
            echo "   必ず完全なログファイル ($FULL_SESSION_LOG_FILE) を確認してください。" >> "$RECOVERY_KEY_ONLY_LOG_FILE"
        fi
    else
        echo "FileVault有効化はユーザーによりキャンセルされました。"
        echo "FileVault有効化はユーザーの選択によりキャンセルされました。" > "$FULL_SESSION_LOG_FILE"
        echo "FileVault有効化がキャンセルされたため、この実行での新しい復旧キーはありません。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
    fi
    rm -f "$TMP_FULL_LOG_FILE"
else
    echo "FileVault有効化プロセスはスキップされました。"
    echo "FileVault有効化はスキップされました。" > "$FULL_SESSION_LOG_FILE"
    echo "理由: FileVaultは既に有効であるか、ステータスが不明確でユーザーがスキップを選択しました。" >> "$FULL_SESSION_LOG_FILE"
    echo "現在のFileVaultステータス (fdesetup statusより): $FV_STATUS" >> "$FULL_SESSION_LOG_FILE"
    echo "FileVault有効化がスキップされたため、この実行での新しい復旧キーはありません。" > "$RECOVERY_KEY_ONLY_LOG_FILE"
    echo "現在のFileVaultステータス (fdesetup statusより): $FV_STATUS" >> "$RECOVERY_KEY_ONLY_LOG_FILE"
    rm -f "$TMP_FULL_LOG_FILE"
fi

# --- SMB操作 (ログファイルのアップロードと共通インストーラーのダウンロード) ---
echo ""
echo "---------------------------------------------------------------------"
echo "📤📂 SMBサーバへのファイル操作 (ログアップロード/インストーラーダウンロード)"
echo "---------------------------------------------------------------------"

echo ""; echo "SMBサーバの情報:"; echo "  サーバアドレス: $SMB_SERVER"; echo "  ユーザー名: $SMB_USER"; echo ""

read -p "ログファイルをSMBサーバにアップロードしますか？ [Y/n]: " UPLOAD_LOGS_SMB_INPUT
USER_CHOICE_UPLOAD_LOGS="${UPLOAD_LOGS_SMB_INPUT:-Y}"

read -p "共通インストーラー等をSMBサーバからデスクトップにダウンロードしますか？ [Y/n]: " DOWNLOAD_FILES_SMB_INPUT
USER_CHOICE_DOWNLOAD_FILES="${DOWNLOAD_FILES_SMB_INPUT:-Y}"

PERFORM_SMB_UPLOAD=false
if [[ "$USER_CHOICE_UPLOAD_LOGS" =~ ^[Yy]$ ]]; then PERFORM_SMB_UPLOAD=true; fi
PERFORM_SMB_DOWNLOAD=false
if [[ "$USER_CHOICE_DOWNLOAD_FILES" =~ ^[Yy]$ ]]; then PERFORM_SMB_DOWNLOAD=true; fi

if [ "$PERFORM_SMB_UPLOAD" = true ] || [ "$PERFORM_SMB_DOWNLOAD" = true ]; then
    read -p "接続するSMB共有名を入力してください [$DEFAULT_SMB_SHARE_NAME]: " INPUT_SMB_SHARE_NAME
    SMB_SHARE_NAME_TO_USE=${INPUT_SMB_SHARE_NAME:-$DEFAULT_SMB_SHARE_NAME}
    if [ -z "$SMB_SHARE_NAME_TO_USE" ]; then echo "⚠️ SMB共有名が指定されなかったため、SMB操作を中止します。"; else
        SMB_URL_FOR_CHECK="//${SMB_USER}@${SMB_SERVER}/${SMB_SHARE_NAME_TO_USE}"; STANDARD_GUI_MOUNT_POINT="/Volumes/${SMB_SHARE_NAME_TO_USE}"
        FINAL_TARGET_BASE=""; DO_MOUNT_UNMOUNT_BY_SCRIPT=true
        echo "SMB接続パスを準備中..."; echo "  標準GUIマウントポイントを確認: ${STANDARD_GUI_MOUNT_POINT}"
        if mount | grep -q -E "^${SMB_URL_FOR_CHECK} on ${STANDARD_GUI_MOUNT_POINT} \\(smbfs"; then
            if [ -d "${STANDARD_GUI_MOUNT_POINT}" ]; then echo "✅ 標準GUIマウントポイント (${STANDARD_GUI_MOUNT_POINT}) が既に存在し、アクティブです。これを使用します。"; FINAL_TARGET_BASE="${STANDARD_GUI_MOUNT_POINT}"; DO_MOUNT_UNMOUNT_BY_SCRIPT=false;
            else echo "ℹ️ マウント情報に ${STANDARD_GUI_MOUNT_POINT} がありますが、ディレクトリとしてアクセスできません。一時マウントを試みます。";fi
        else echo "ℹ️ 標準GUIマウントポイントは使用されていません、または目的の共有ではありません。一時マウントを試みます。";fi
        LOCAL_TEMP_MOUNT_POINT=""
        if [ "$DO_MOUNT_UNMOUNT_BY_SCRIPT" = true ]; then
            LOCAL_TEMP_MOUNT_POINT="/tmp/smb_ops_mount_$$_$(date +%s)"; CAN_PROCEED_WITH_TEMP_MOUNT=true
            if mount | grep -q -F " on ${LOCAL_TEMP_MOUNT_POINT} "; then echo "⚠️ 致命的エラー: 一時マウントポイントパス '${LOCAL_TEMP_MOUNT_POINT}' は既に他のファイルシステムとして使用されています。"; CAN_PROCEED_WITH_TEMP_MOUNT=false;
            else mkdir -p "$LOCAL_TEMP_MOUNT_POINT"; if [ ! -d "$LOCAL_TEMP_MOUNT_POINT" ]; then echo "⚠️ 一時マウントポイントの作成に失敗しました: $LOCAL_TEMP_MOUNT_POINT"; CAN_PROCEED_WITH_TEMP_MOUNT=false; fi;fi
            
            # <--- 修正部分 開始 ---
            if [ "$CAN_PROCEED_WITH_TEMP_MOUNT" = true ]; then
                while true; do
                    MOUNT_URL="//${SMB_USER}@${SMB_SERVER}/${SMB_SHARE_NAME_TO_USE}"
                    echo "SMB共有を一時マウント準備中..."; 
                    echo "  マウントポイント: $LOCAL_TEMP_MOUNT_POINT"
                    echo "  マウントURL: $MOUNT_URL"
                    echo "ℹ️ SMB共有のマウントを試みます。Kerberos認証が利用できない場合、システムがパスワード入力を求めることがあります。"
                    
                    mount_smbfs "$MOUNT_URL" "$LOCAL_TEMP_MOUNT_POINT"
                    
                    if [ $? -eq 0 ]; then
                        echo "✅ SMB共有の一時マウントに成功しました。"
                        FINAL_TARGET_BASE="$LOCAL_TEMP_MOUNT_POINT"
                        break 
                    else
                        echo "⚠️ SMB共有の一時マウントに失敗しました。"
                        echo "   ユーザー名、共有名、またはパスワードが間違っている可能性があります。"
                        read -p "再試行しますか？ (キャンセルする場合は n を入力) [Y/n]: " RETRY_SMB_MOUNT_INPUT
                        USER_CHOICE_RETRY_SMB="${RETRY_SMB_MOUNT_INPUT:-Y}"
                        
                        if [[ "$USER_CHOICE_RETRY_SMB" =~ ^[Yy]$ ]]; then
                            echo "了解しました。もう一度試みます..."
                            echo ""
                        else
                            echo "SMBマウントをキャンセルしました。"
                            if [ -d "$LOCAL_TEMP_MOUNT_POINT" ]; then
                                rmdir "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1
                            fi
                            LOCAL_TEMP_MOUNT_POINT=""
                            break 
                        fi
                    fi
                done
            else
                 LOCAL_TEMP_MOUNT_POINT=""
            fi
            # <--- 修正部分 終了 ---
        fi
        if [ -n "$FINAL_TARGET_BASE" ]; then
            if [ "$PERFORM_SMB_UPLOAD" = true ]; then
                echo ""; echo "--- ログファイルのアップロード開始 ---"; DEFAULT_SMB_LOG_UPLOAD_PATH="macOS_filevault_key_backup"
                read -p "ログの保存先ディレクトリパス (共有 '${SMB_SHARE_NAME_TO_USE}' 内) を入力してください [$DEFAULT_SMB_LOG_UPLOAD_PATH]: " INPUT_SMB_LOG_UPLOAD_PATH
                SMB_LOG_UPLOAD_PATH_TO_USE=${INPUT_SMB_LOG_UPLOAD_PATH:-$DEFAULT_SMB_LOG_UPLOAD_PATH}; SMB_LOG_UPLOAD_PATH_CLEAN=""
                if [ -n "$SMB_LOG_UPLOAD_PATH_TO_USE" ]; then SMB_LOG_UPLOAD_PATH_CLEAN=$(echo "$SMB_LOG_UPLOAD_PATH_TO_USE" | sed 's#^/*##' | sed 's#/*$##'); fi
                FINAL_LOG_UPLOAD_DIR_ON_SMB="$FINAL_TARGET_BASE"; if [ -n "$SMB_LOG_UPLOAD_PATH_CLEAN" ]; then FINAL_LOG_UPLOAD_DIR_ON_SMB="${FINAL_TARGET_BASE}/${SMB_LOG_UPLOAD_PATH_CLEAN}"; fi
                echo "ログアップロード先ディレクトリ: ${FINAL_LOG_UPLOAD_DIR_ON_SMB}"; echo "ディレクトリを作成 (または確認) 中..."; mkdir -p "${FINAL_LOG_UPLOAD_DIR_ON_SMB}"
                if [ ! -d "${FINAL_LOG_UPLOAD_DIR_ON_SMB}" ]; then echo "⚠️ ログアップロード先ディレクトリの作成/確認に失敗しました: ${FINAL_LOG_UPLOAD_DIR_ON_SMB}";
                else
                    if [ -f "$FULL_SESSION_LOG_FILE" ]; then echo "rsync を使用して完全セッションログ '$FULL_SESSION_LOG_FILE' をアップロード中 (進捗表示あり)..."; rsync -ah --progress "$FULL_SESSION_LOG_FILE" "${FINAL_LOG_UPLOAD_DIR_ON_SMB}/"; if [ $? -eq 0 ]; then echo "✅ 完全セッションログのアップロードに成功しました。"; else echo "⚠️ 完全セッションログのアップロードに失敗しました。"; fi;
                    else echo "⚠️ 完全セッションログファイル '$FULL_SESSION_LOG_FILE' が見つからないため、アップロードをスキップします。"; fi; echo ""
                    if [ -f "$RECOVERY_KEY_ONLY_LOG_FILE" ]; then echo "rsync を使用して復旧キーログ '$RECOVERY_KEY_ONLY_LOG_FILE' をアップロード中 (進捗表示あり)..."; rsync -ah --progress "$RECOVERY_KEY_ONLY_LOG_FILE" "${FINAL_LOG_UPLOAD_DIR_ON_SMB}/"; if [ $? -eq 0 ]; then echo "✅ 復旧キーログのアップロードに成功しました。"; else echo "⚠️ 復旧キーログのアップロードに失敗しました。"; fi;
                    else echo "⚠️ 復旧キーログファイル '$RECOVERY_KEY_ONLY_LOG_FILE' が見つからないため、アップロードをスキップします。"; fi;
                fi; echo "--- ログファイルのアップロード終了 ---"
            fi
            if [ "$PERFORM_SMB_DOWNLOAD" = true ]; then
                echo ""; echo "--- 共通インストーラーのダウンロード確認 ---"
                SMB_D_APP_PATH_ON_SHARE="Symantec/SEP Cloud版 オンラインインストーラー 14.3 RU9(Tokyo_Mac)/Install Symantec Endpoint Protection.app"; SMB_D_PKG_FILE_PATH_ON_SHARE="Software/Microsoft_365_and_Office_16.87.24071426_BusinessPro_Installer.pkg"
                USER_DESKTOP_PATH=""; LOGGED_IN_USER=$(stat -f%Su /dev/console)
                if [ -n "$LOGGED_IN_USER" ] && [ "$LOGGED_IN_USER" != "root" ]; then USER_HOME_DIR=$(dscl . -read "/Users/$LOGGED_IN_USER" NFSHomeDirectory | awk '{print $2}'); if [ -d "$USER_HOME_DIR/Desktop" ]; then USER_DESKTOP_PATH="$USER_HOME_DIR/Desktop"; fi;fi
                if [ -z "$USER_DESKTOP_PATH" ] || ! [ -d "$USER_DESKTOP_PATH" ] ; then USER_DESKTOP_PATH="$HOME/Desktop"; fi
                if [ ! -d "$USER_DESKTOP_PATH" ]; then echo "⚠️ ダウンロード先デスクトップフォルダが見つかりません。ダウンロード処理を中止します。"; else
                    echo "ダウンロード先デスクトップ: $USER_DESKTOP_PATH"; USER_CHOICE_DOWNLOAD_APP_CONFIRMED=false; USER_CHOICE_DOWNLOAD_PKG_CONFIRMED=false
                    APP_NAME_TO_COPY=$(basename "$SMB_D_APP_PATH_ON_SHARE"); echo ""; echo "ダウンロード候補 1: アプリケーション「${APP_NAME_TO_COPY}」"; echo "  (共有上のフルパス: $SMB_D_APP_PATH_ON_SHARE)"
                    read -p "このアプリケーションをデスクトップにダウンロードしますか？ [Y/n]: " CONFIRM_DOWNLOAD_APP_INPUT; if [[ "${CONFIRM_DOWNLOAD_APP_INPUT:-Y}" =~ ^[Yy]$ ]]; then USER_CHOICE_DOWNLOAD_APP_CONFIRMED=true; fi
                    PKG_NAME_TO_COPY=$(basename "$SMB_D_PKG_FILE_PATH_ON_SHARE"); echo ""; echo "ダウンロード候補 2: パッケージ「${PKG_NAME_TO_COPY}」"; echo "  (共有上のフルパス: $SMB_D_PKG_FILE_PATH_ON_SHARE)"
                    read -p "このパッケージをデスクトップにダウンロードしますか？ [Y/n]: " CONFIRM_DOWNLOAD_PKG_INPUT; if [[ "${CONFIRM_DOWNLOAD_PKG_INPUT:-Y}" =~ ^[Yy]$ ]]; then USER_CHOICE_DOWNLOAD_PKG_CONFIRMED=true; fi
                    echo ""; DOWNLOADS_ATTEMPTED=0; DOWNLOADS_SUCCEEDED=0
                    if [ "$USER_CHOICE_DOWNLOAD_APP_CONFIRMED" = true ]; then
                        DOWNLOADS_ATTEMPTED=$((DOWNLOADS_ATTEMPTED + 1)); APP_NAME_TO_COPY_EXEC=$(basename "$SMB_D_APP_PATH_ON_SHARE")
                        echo "--- アプリケーション「${APP_NAME_TO_COPY_EXEC}」のダウンロード処理実行 ---"; SOURCE_APP_FULL_PATH="${FINAL_TARGET_BASE}/${SMB_D_APP_PATH_ON_SHARE}"; echo "rsync を使用してコピー中 (進捗表示あり)..."
                        if [ -d "$SOURCE_APP_FULL_PATH" ]; then rsync -ah --progress "$SOURCE_APP_FULL_PATH" "$USER_DESKTOP_PATH/"; if [ $? -eq 0 ]; then echo "✅ アプリケーション「${APP_NAME_TO_COPY_EXEC}」のコピーに成功しました。"; DOWNLOADS_SUCCEEDED=$((DOWNLOADS_SUCCEEDED + 1)); else echo "⚠️ アプリケーション「${APP_NAME_TO_COPY_EXEC}」のコピーに失敗しました。"; fi
                        else echo "⚠️ コピー元アプリケーション「${APP_NAME_TO_COPY_EXEC}」が見つかりません: \"$SOURCE_APP_FULL_PATH\""; fi; echo ""
                    fi
                    if [ "$USER_CHOICE_DOWNLOAD_PKG_CONFIRMED" = true ]; then
                        DOWNLOADS_ATTEMPTED=$((DOWNLOADS_ATTEMPTED + 1)); PKG_NAME_TO_COPY_EXEC=$(basename "$SMB_D_PKG_FILE_PATH_ON_SHARE")
                        echo "--- パッケージ「${PKG_NAME_TO_COPY_EXEC}」のダウンロード処理実行 ---"; SOURCE_PKG_FILE_FULL_PATH="${FINAL_TARGET_BASE}/${SMB_D_PKG_FILE_PATH_ON_SHARE}"; echo "rsync を使用してコピー中 (進捗表示あり)..."
                        if [ -f "$SOURCE_PKG_FILE_FULL_PATH" ]; then rsync -ah --progress "$SOURCE_PKG_FILE_FULL_PATH" "$USER_DESKTOP_PATH/"; if [ $? -eq 0 ]; then echo "✅ ファイル「${PKG_NAME_TO_COPY_EXEC}」のコピーに成功しました。"; DOWNLOADS_SUCCEEDED=$((DOWNLOADS_SUCCEEDED + 1)); else echo "⚠️ ファイル「${PKG_NAME_TO_COPY_EXEC}」のコピーに失敗しました。"; fi
                        else echo "⚠️ コピー元ファイル「${PKG_NAME_TO_COPY_EXEC}」が見つかりません: \"$SOURCE_PKG_FILE_FULL_PATH\""; fi; echo ""
                    fi
                    echo ""; if [ "$DOWNLOADS_ATTEMPTED" -eq 0 ]; then if [ "$USER_CHOICE_DOWNLOAD_APP_CONFIRMED" = false ] && [ "$USER_CHOICE_DOWNLOAD_PKG_CONFIRMED" = false ]; then echo "個別の確認ですべてのアイテムがスキップされたため、ダウンロードは実行されませんでした。"; fi
                    elif [ "$DOWNLOADS_ATTEMPTED" -gt 0 ]; then if [ "$DOWNLOADS_SUCCEEDED" -gt 0 ]; then echo "${DOWNLOADS_SUCCEEDED}件のアイテムのダウンロードが完了しました。"; fi; if [ "$DOWNLOADS_SUCCEEDED" -lt "$DOWNLOADS_ATTEMPTED" ]; then echo "$((DOWNLOADS_ATTEMPTED - DOWNLOADS_SUCCEEDED))件のアイテムはダウンロードに失敗したか、見つかりませんでした。"; fi; fi
                fi; echo ""; echo "--- 共通インストーラーのダウンロード処理終了 ---"
            fi
            if [ "$DO_MOUNT_UNMOUNT_BY_SCRIPT" = true ] && [ -n "$LOCAL_TEMP_MOUNT_POINT" ]; then
                if [ ! -d "$LOCAL_TEMP_MOUNT_POINT" ]; then echo "ℹ️ 一時マウントポイントディレクトリ ${LOCAL_TEMP_MOUNT_POINT} が存在しません。アンマウント処理は不要または実行不可能です。"; else
                    echo ""; echo "ℹ️ アンマウント前にシステムがファイル操作を完了するための待機時間を設けます (3秒)..."; sleep 3
                    echo "一時SMB共有 ($LOCAL_TEMP_MOUNT_POINT) のアンマウントを試みます..."; UNMOUNT_OUTPUT_NORMAL=$(diskutil unmount "$LOCAL_TEMP_MOUNT_POINT" 2>&1); UNMOUNT_STATUS_NORMAL=$?
                    if [ $UNMOUNT_STATUS_NORMAL -eq 0 ]; then echo "✅ 一時SMB共有のアンマウントに成功しました (通常)。"; sleep 1; else
                        if echo "$UNMOUNT_OUTPUT_NORMAL" | grep -q -i "not currently mounted"; then echo "ℹ️ 一時SMB共有は既にアンマウントされているようです (通常試行時)。"; else
                            echo "⚠️ 通常のアンマウントに失敗しました。エラー: $UNMOUNT_OUTPUT_NORMAL"; echo "   強制アンマウントを試みます..."; UNMOUNT_OUTPUT_FORCE=$(diskutil unmount force "$LOCAL_TEMP_MOUNT_POINT" 2>&1); UNMOUNT_STATUS_FORCE=$?
                            if [ $UNMOUNT_STATUS_FORCE -eq 0 ]; then echo "✅ 一時SMB共有のアンマウントに成功しました (強制)。"; sleep 1;
                            elif echo "$UNMOUNT_OUTPUT_FORCE" | grep -q -i "not currently mounted"; then echo "ℹ️ 一時SMB共有は既にアンマウントされているようです (強制試行後)。";
                            else echo "⚠️ 強制アンマウントにも失敗しました。エラー: $UNMOUNT_OUTPUT_FORCE"; echo "   手動でアンマウントする必要があるかもしれません: $LOCAL_TEMP_MOUNT_POINT"; echo "   試行コマンド例: sudo diskutil unmount force \"$LOCAL_TEMP_MOUNT_POINT\"";fi
                        fi
                    fi
                    rmdir "$LOCAL_TEMP_MOUNT_POINT" >/dev/null 2>&1
                    if [ -d "$LOCAL_TEMP_MOUNT_POINT" ]; then echo "ℹ️ 一時マウントポイントディレクトリ $LOCAL_TEMP_MOUNT_POINT は削除できませんでした。手動での確認が必要な場合があります。"; else echo "✅ 一時マウントポイントディレクトリ $LOCAL_TEMP_MOUNT_POINT を削除しました。"; fi
                fi
            elif [ "$DO_MOUNT_UNMOUNT_BY_SCRIPT" = false ] && [ -n "$FINAL_TARGET_BASE" ]; then echo ""; echo "ℹ️ 既存のマウントポイント (${FINAL_TARGET_BASE}) を使用したので、スクリプトはアンマウントを行いませんでした。";fi
        else echo "⚠️ SMB接続またはマウントに失敗したため、ファイル操作を中止します。"; fi
    fi
else echo "SMBサーバへのファイル操作（アップロード・ダウンロード）はスキップされました。"; fi


echo ""
echo "---------------------------------------------------------------------"
echo "🚨🚨 再確認: 画面に表示された、または完全ログに記録された個人用復旧キーを、"
echo "   安全な場所に確実に保管したことを確認してください！ 🚨🚨"
echo "---------------------------------------------------------------------"

exit 0