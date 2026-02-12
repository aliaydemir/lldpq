VRF=$(ip vrf identify)
[ -n "${VRF}" ] && VRF="${VRF}"
export VRF

PS1='\[\e[1;33m\][\[\e[0;31m\]\h\[\e[1;33m\]] \[\e[1;33m\][\[\e[1;31m\]'${VRF}'\[\e[1;33m\]] \[\e[1;35m\][\[\e[0;33m\]\W\[\e[1;35m\]] \[\e[1;34m\]\$\[\e[0m\] '
PS2='\[\e[0;31m\]Here_You_Are\[\e[m > '

rm -f $HOME/.lesshst
rm -f $HOME/.rnd
rm -f $HOME/.viminfo
rm -f $HOME/.wget-hsts

stty -ixon
shopt -s checkwinsize
shopt -s histappend

export TERM=xterm-256color
export EDITOR='nano -cu'
export VISUAL='nano -cu'
export LESSHISTFILE=-
export WGETRC=/dev/null

[[ -r "/usr/share/z/z.sh" ]] && source /usr/share/z/z.sh

HISTCONTROL=ignoredups:ignorespace
HISTSIZE=10000000
HISTFILESIZE=10000000
HISTTIMEFORMAT='%d-%m-%Y %T => '

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias ......='cd ../../../../..'

alias ls="ls -A --color=auto"

#alias ld="ls -A --color=auto"
#alias l="ls -lh --color=auto --time-style=+'%g %b %d %H:%M'"
#alias ll="ls -lhA --color=auto --time-style=+'%g %b %d %H:%M'"
#alias lh="ls -lhAtr --color=auto --time-style=+'%g %b %d %H:%M'"

alias l="exa -lh --color=always --group-directories-first"
alias ll="exa -lah --color=always --group-directories-first"
alias lll="exa -lahg --color=always --group-directories-first"
alias lls="exa -as name --color=always"

alias lg="exa -lah --color=always --icons --group-directories-first --git"
alias ld="exa -lahgmDs name --group-directories-first --color=always --icons"
alias lh="exa -lahgms modified --color=always --icons"

alias lt="exa -lahgmT --color=always --icons --group-directories-first"
alias lt1="exa -lahgmT -L 1 --color=always --icons --group-directories-first"
alias lt2="exa -lahgmT -L 2 --color=always --icons --group-directories-first"
alias lt3="exa -lahgmT -L 3 --color=always --icons --group-directories-first"
alias lth="exa -lahgmTs modified --color=always --icons --group-directories-first"

alias free='free -h'
alias dirs='dirs -v'
alias ss4='sudo netstat -4tulpn | grep -v 127.0.0'
alias ss6='sudo netstat -6tulpn | grep -v 127.0.0'
alias SS='sudo netstat -tulpn | grep -v 127 | uniq'

alias du1='sudo du -xch --max-depth=1 2> /dev/null | sort -h'
alias du1m='sudo du -xcm --max-depth=1 2> /dev/null | sort -h'
alias du1k='sudo du -xck --max-depth=1 2> /dev/null | sort -h'
alias du2='sudo du -xch --max-depth=2 2> /dev/null | sort -h'

alias dmesg='sudo dmesg -L'
alias cal='ncal -b -M -h'
alias car='cat -n'
alias cay='cat -ne'
alias can="grep -v '^#'"
alias mkdir='mkdir -pv'
alias nn='nano -cu'
alias nnl='nano -lcu'
alias ping='ping -c 5'
alias ping6='ping -6 -c 5'
alias c="clear"
alias h="history"
alias grep="grep --color=auto"
alias egrep="egrep --color=auto"
alias fgrep="fgrep --color=auto"
alias rr4="sudo route -n"
alias rr6="sudo route -6 -n"
alias clock="date +'%T'"
alias sys="systemctl --type=service"
alias syss="systemctl list-unit-files"
alias iff='ifconfig | sed -E -e "/127/! s|([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)|$(tput setab 1)$(tput setaf 0)\1\.\2\.\3\.\4$(tput sgr0)|"'
alias ipp='echo ""; ifconfig | grep inet |  grep -v inet6 | grep -v 127 | sed -E -e "s|([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(.*)|$(tput setab 1)$(tput setaf 0)\1\.\2\.\3\.\4$(tput sgr0)\5\n|"'
alias sudo="sudo "
alias src="source /etc/profile"
alias cumulus="su - cumulus"
alias root="sudo su -"

alias nvo='nv config show -o commands'
alias nva='nv config apply -y'
alias nvd='nv config diff'
alias nvl='nv config show -o commands | less -X'
alias nvs='nv config show'

__vrfs() { ip vrf | awk 'NR>2 {print $1}'; }

function nvg () { nv config show -o commands | grep "$*"; }
function vty () { sudo vtysh -c "$*" ;}
function rr () { sudo vtysh -c "show ip route vrf $1"; }
function rr- () { while read -r vrf; do echo -e "\n------\e[1;37;41m ${vrf} \e[0m------\n"; sudo vtysh -c "show ip route vrf $vrf"; done < <(__vrfs); }
function rr-- () { echo -e "\n------\e[1;37;41m default \e[0m------\n"; sudo vtysh -c "show ip route vrf default"; while read -r vrf; do echo -e "\n------\e[1;37;41m ${vrf} \e[0m------\n"; sudo vtysh -c "show ip route vrf $vrf"; done < <(__vrfs); }
function bvlan() { printf "%-20s %-10s %s\n" "PORT" "PVID" "VLANs"; printf "%-20s %-10s %s\n" "----" "----" "-----"; /usr/sbin/bridge vlan | awk 'BEGIN{cp=""} NR==1||NF==0{next} NF>=2{if(cp!="")print cp "|" p "|" v; cp=$1; p=""; v=$2; if($3=="PVID")p=$2; next} NF==1{v=v","$1} NF>2&&$3=="PVID"{p=$2; v=v","$2} END{if(cp!="")print cp "|" p "|" v}' | awk -F"|" '{if($1~/^vxlan/)n=99999; else if(match($1,/[0-9]+$/))n=substr($1,RSTART,RLENGTH); else n=99999; printf "%04d|%s|%s|%s\n",n,$1,$2,$3}' | sort -n | awk -F"|" '{printf "%-20s PVID=%-5s VLANs=%s\n",$2,($3?$3:"N/A"),$4}'; }
function pink () { vrf task exec "$1" ping "${@:2}"; }
function vvh () { vrf task exec "$1" ssh "${@:2}"; }
function vshell () { vrf task exec "$1" bash; }
function macs () { /usr/sbin/bridge fdb | grep "$*" | sorti 3 ; }
function arps () { /usr/sbin/ip -4 neighbor | grep "$*" | sorti 1 | column -t ; }

function hgrep () { history | grep -i --color "$1"; }
function mgrep () { sudo grep -rnIi --color "$1" "${@: 2}"; }
function cgrep () { sudo grep --color=always -e "^" -e "$1" "${@: 2}"; }
function x () { for run in {1..99}; do echo ""; done  }
function dff () { DFF0=$(df -HT | head -n 1);DFF1=$(df -HT | grep "/dev/root");DFF2=$(df -HT | grep "/dev/sda");DFF=$(sudo df -HT | grep -v tmpfs | grep -v root | grep -v sda| grep -v snap | grep -v www | tail -n +2);FRR0=$(free | head -n 1);FRR1=$(sudo free -h | tail -n +2);FRR2=$(sudo free -ht | grep Total);echo "";echo -e "\e[1;32m$DFF0\e[0m";echo -e "\e[1;33m$DFF1\e[0m";echo -e "\e[0;31m$DFF2\e[0m";echo"";echo -e "\e[1;31m$DFF\e[0m";echo "";echo -e "\e[1;32m$FRR0\e[0m";echo -e "\e[1;33m$FRR1\e[0m";echo -e "\e[1;31m$FRR2\e[0m";echo ""; }
function pss () { sudo ps -ef | grep $1 | grep -v grep; }
function psk () { sudo ps auxf | grep -v \\[ | grep -v ps ; }

function cale () {
DATE=$(date +'%d-%m-%Y')
CLOK=$(date +'%T')
BOLD=$(tput bold)
BGCL=$(tput setab 1)
FGCL=$(tput setaf 3)
REVE=$(tput rev)
RSET=$(tput sgr0)
DAYS=$(date +%-e)
if [[ "$DAYS" == 1 ]] || [[ "$DAYS" == 2 ]] || [[ "$DAYS" == 3 ]]; then
if [ $(date +%w) = 0 ]; then
CALL=$(ncal -b -M -h | sed -E -e "s/($(date +%B)) ($(date +%Y))/$(tput bold)$(tput setaf 2)$(tput smul)\1$(tput rmul) $(tput setaf 1)$(tput smul)\2$(tput sgr0)/" | sed -E -e "/$(date +%Y)/!s|(.*[^0-9])($DAYS)([^0-9]*$)|\1$BGCL$BOLD$FGCL\2$RSET\3|")
else
CALL=$(ncal -b -M -h | sed -E -e "s/($(date +%B)) ($(date +%Y))/$(tput bold)$(tput setaf 2)$(tput smul)\1$(tput rmul) $(tput setaf 1)$(tput smul)\2$(tput sgr0)/" | sed -E -e "/$(date +%Y)/!s|(.*[^0-9])($DAYS)([^0-9]$*)|\1$BGCL$BOLD$FGCL\2$RSET\3|")
fi
elif [[ "$DAYS" == [0-9] ]]; then
CALL=$(ncal -b -M -h | sed -E -e "s/($(date +%B)) ($(date +%Y))/$(tput bold)$(tput setaf 2)$(tput smul)\1$(tput rmul) $(tput setaf 1)$(tput smul)\2$(tput sgr0)/" | sed -E -e "/$(date +%Y)/!s|(.*[^0-9])($DAYS)|\1$BGCL$BOLD$FGCL\2$RSET|")
else
CALL=$(ncal -b -M -h | sed -E -e"s/($(date +%B)) ($(date +%Y))/$(tput bold)$(tput setaf 2)$(tput smul)\1$(tput rmul) $(tput setaf 1)$(tput smul)\2$(tput sgr0)/" | sed -E -e "/$(date +%Y)/!s|(.*[^0-9]?)($DAYS)|\1$BGCL$BOLD$FGCL\2$RSET|")
fi
echo -e ""
echo -e "     \e[1;34m$DATE\e[0m"
echo -e "      \e[1;33m$CLOK\e[0m"
echo -e ""
paste <(echo -e "$CALL")
}

function sorti() {
    args=()
    for arg in "$@"; do
        col="${arg%[A-Za-z]}"
        type="${arg##*[0-9]}"
        case "$type" in
            n) args+=("-k${col},${col}n") ;;    # numeric
            V|"") args+=("-k${col},${col}V") ;; # default or explicit V
            *) args+=("-k${col},${col}V") ;;    # fallback = natural
        esac
    done
    sort "${args[@]}"
}