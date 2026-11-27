#!/bin/zsh
# Read check test: tests/peek.zsh. The 18 reads must pass and the 33 commands to refuse must be refused
source "${0:A:h:h}/lib/peek.zsh"
ok=( 'system_profiler SPHardwareDataType | grep -i udid' 'ioreg -rd1 -c IOPlatformExpertDevice' 'pgrep -fl MyApp' 'ls -la ~/Shared-Test' 'cat ~/x.txt | wc -l' 'sqlite3 -readonly ~/a.sqlite "select kind from items limit 3"' '/usr/bin/log show --last 2m --predicate "process == \"x\""' '/bin/ls -la ~' '/usr/sbin/sysctl -n hw.memsize' 'defaults read com.example.myapp' 'launchctl print gui/501/com.example.myapp.server' 'find ~/Shared-Test -name "*.bin"' 'scutil --get ComputerName' 'netstat -an -p tcp | grep 7390' 'stat -f %z ~/a' 'codesign -dv /Applications/X.app' 'plutil -p ~/Library/Preferences/a.plist' "awk '{print \$1}' /etc/hosts" )
no=( 'rm -rf ~/Shared-Test' 'ls; rm x' 'ls && rm x' 'cat a > b' 'echo $(rm x)' 'ls `rm x`' 'sudo ls' 'find . -delete' 'find . -exec rm {} ;' 'sqlite3 ~/a.sqlite "delete from items"' 'sqlite3 -readonly a ".shell rm x"' 'defaults write a b c' 'launchctl kill KILL gui/501/x' 'log erase' 'xattr -d com.apple.quarantine x' 'sysctl -w a=1' 'codesign -s - x' 'open -a Finder' 'touch x' 'ls || rm x' 'tee x' 'sort -o a b' "awk 'BEGIN{system(\"rm x\")}'" 'scutil --set ComputerName x' 'cua-driver call screenshot' 'killall Finder' 'plutil -replace a -string b x.plist' 'pluginkit -e use -i x' 'log show --last 1m' '/usr/bin/log erase' '/tmp/cat x' '/usr/bin/../../tmp/log show' '/usr/sbin/sysctl -w a=1' )
pass=0 fail=0
for c in $ok; do if peek_allowed "$c" 2>/dev/null; then (( pass++ )); else print "wrong (refused): $c"; (( fail++ )); fi; done
for c in $no; do if peek_allowed "$c" 2>/dev/null; then print "wrong (allowed): $c"; (( fail++ )); else (( pass++ )); fi; done
print "of ${#ok} reads and ${#no} refusals: right $pass, wrong $fail"
(( fail == 0 ))
