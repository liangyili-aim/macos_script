#!/bin/zsh

if sudo fdesetup status | grep -q "FileVault is On."; then
    echo "  FileVaultが有効なため、新しいユーザーをロック解除ユーザーとして追加します..."
    CURRENT_ADMIN_USER="${SUDO_USER:-$(whoami)}"
    if sudo fdesetup add -usertoadd "$NEW_ADMIN_SHORTNAME" -user "$CURRENT_ADMIN_USER"; then
        echo "  ✅ ユーザー「${NEW_ADMIN_SHORTNAME}」がFileVaultのロック解除ユーザーとして正常に追加されました。"
    else
        echo "  ⚠️ ユーザー「${NEW_ADMIN_SHORTNAME}」をFileVaultに追加できませんでした。パスワードが間違っているか、権限に問題がある可能性があります。"
    fi
    unset CURRENT_ADMIN_PASSWORD
else
    echo "  ℹ️ FileVaultが無効または有効化中のため、現時点でのユーザー追加はスキップされました。"
fi