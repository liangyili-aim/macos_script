#!/bin/zsh

# スクリプト全体のロケールを日本語UTF-8に設定 (文字化け対策)
export LC_ALL=ja_JP.UTF-8

TMP_FULL_LOG_FILE=$(mktemp) # 一時ファイルは最初に作成


# --- コンピュータ名とローカルホスト名の設定 ---
# (この部分は前回のスクリプトから変更なし)
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

# ログファイル名表示ブロック
echo "---------------------------------------------------------------------"
echo "ログファイルは以下の名前で保存されます:"
echo "  復旧キー専用ログ: $RECOVERY_KEY_ONLY_LOG_FILE"
echo "  完全セッションログ: $FULL_SESSION_LOG_FILE"
echo "---------------------------------------------------------------------"
echo ""

# --- FileVaultステータス確認と有効化プロセス ---
# (この部分は前回のスクリプトから変更なし)
echo "🔒 FileVault の状態を確認します..."
FV_STATUS=$(sudo fdesetup status)
echo "現在のFileVaultステータス: $FV_STATUS"

PERFORM_FV_ENABLEMENT=false
CURRENT_ADMIN_USER="${SUDO_USER:-$(whoami)}"

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
        script -q "$TMP_FULL_LOG_FILE" sudo fdesetup enable -u "$CURRENT_ADMIN_USER"
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