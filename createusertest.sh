#!/bin/zsh

# --- 新しい管理者ユーザーの追加 ---
CURRENT_ADMIN_USER="${SUDO_USER:-$(whoami)}" # 現在の管理者ユーザーを取得
echo ""
echo "---------------------------------------------------------------------"
echo "👤 新しい管理者ユーザーアカウントの作成"
echo "---------------------------------------------------------------------"
read -p "新しい管理者ユーザーを作成しますか？ [Y/n]: " CREATE_NEW_ADMIN_INPUT_VAL 
read -sp "管理者 $CURRENT_ADMIN_USER のパスワードを入力してください: " ADMIN_PASSWORD_INPUT
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

            USER_CREATE_SUCCESS=false
            echo "  sysadminctlを使用してユーザーレコードを作成中..."
            
            NEW_USER_PASSWORD="aim20110601" 
            echo "  警告: スクリプト内にパスワードを直接記述することはセキュリティ上推奨されません。"
            
            # set -eを一時的に無効にしてエラーハンドリングを手動で行う
            set +e
            sudo sysadminctl -addUser "$NEW_ADMIN_SHORTNAME" -fullName "$NEW_ADMIN_FULLNAME" -shell "/bin/zsh" -password "$NEW_USER_PASSWORD" -admin
            USER_CREATE_RESULT=$?
            set -e
            
            if [ $USER_CREATE_RESULT -eq 0 ]; then
                echo "  ✅ sysadminctlによるユーザー作成に成功しました。"
                echo "  (ユーザー、ホームディレクトリ、管理者権限がすべて設定されました)"
                USER_CREATE_SUCCESS=true
                if sudo sysadminctl -adminUser $CURRENT_ADMIN_USER -adminPassword $ADMIN_PASSWORD_INPUT -secureTokenOn "$NEW_ADMIN_SHORTNAME" -password "$NEW_USER_PASSWORD"; then
                    echo "  ✅ ユーザー「${NEW_ADMIN_SHORTNAME}」にSecureTokenが正常に設定されました。"
                else
                    echo "  ⚠️ ユーザー「${NEW_ADMIN_SHORTNAME}」のSecureToken設定に失敗しました。"
                fi
            else 
                echo "⚠️ sysadminctlによるユーザー作成に失敗しました。"
            fi

            if [ "$USER_CREATE_SUCCESS" = true ]; then
                 echo "✅ 新しい管理者ユーザー「${NEW_ADMIN_SHORTNAME}」のsysadminctlによる作成が完了しました。"
            else
                echo "ユーザー「${NEW_ADMIN_SHORTNAME}」のsysadminctlによる作成プロセス中にエラーが発生しました。"
                echo "必要に応じて手動で確認・削除してください: (例: sudo sysadminctl -deleteUser \"$NEW_ADMIN_SHORTNAME\")"
            fi
        fi
    fi
else
    echo "新しい管理者ユーザーの作成はスキップされました。"
fi
echo "---------------------------------------------------------------------"
echo ""