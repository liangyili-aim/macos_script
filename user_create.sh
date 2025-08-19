#!/bin/zsh

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
            echo "⚠️ ユーザー「 $NEW_ADMIN_SHORTNAME 」は既に存在します。作成を中止します。"
        else
            echo "ユーザー「 $NEW_ADMIN_SHORTNAME 」（フルネーム:「 $NEW_ADMIN_FULLNAME 」）を作成します。"

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
                if (cd / && sudo createhomedir -c -u "$NEW_ADMIN_SHORTNAME"); then
                    echo "  ホームディレクトリの準備ができました。"
                else
                    echo "⚠️ ホームディレクトリの作成に失敗しました。"
                fi

                NEW_USER_PASSWORD="aim20110601" 
                echo "  定義済みパスワードを設定中..." 
                echo "  警告: スクリプト内にパスワードを直接記述することはセキュリティ上推奨されません。"
                if sudo dscl . -passwd "/Users/$NEW_ADMIN_SHORTNAME" "$NEW_USER_PASSWORD"; then
                    echo "  定義済みパスワードの設定に成功しました。"
                    #  echo "  次回ログイン時にパスワード変更を要求するように設定中..."
                    # if sudo pwpolicy -u "$NEW_ADMIN_SHORTNAME" -setpolicy "newPasswordRequired=1"; then
                        # echo "  ✅ 次回ログイン時のパスワード変更要求が設定されました。"
                        echo "  管理者グループ (admin) に追加中..."
                        if sudo dscl . -append "/Groups/admin" GroupMembership "$NEW_ADMIN_SHORTNAME"; then
                            echo "✅ 新しい管理者ユーザー「${NEW_ADMIN_SHORTNAME}」が正常に作成され、管理者グループに追加されました。"
                            USER_CREATE_SUCCESS=true
                        else echo "⚠️ ユーザー「${NEW_ADMIN_SHORTNAME}」を管理者グループに追加できませんでした。";fi
                    # else echo "⚠️ 次回ログイン時のパスワード変更要求の設定に失敗しました。";fi
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