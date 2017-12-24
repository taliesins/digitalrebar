#!/bin/bash

usage() {
	echo "Usage: $0 [--access=<MODE>] [--admin-ip=<admin ip>] [--con-provisioner] [--con-dhcp]"
	echo "Defaults are: "
	echo "  MODE = HOST (instead of FORWARDER)"
	echo "  admin ip = IP of interface with the default gateway or first global address"
	echo "  No DHCP or Provisioner Components"
	exit 1
}

IPADDR=""
ACCESS=""
args=()
while (( $# > 0 )); do
    arg="$1"
    arg_key="${arg%%=*}"
    arg_data="${arg#*=}"
    case $arg_key in
        # This used to process init-files.sh and workload.sh args
        --con-*)
            args+=("$arg");;
        --wl-*)
            args+=("$arg");;
        --admin-ip)
            IPADDR=$arg
            ;;
        --access)
            ACCESS=$arg
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            arg_key="${arg_key#--}"
            arg_key="${arg_key//-/_}"
            arg_key="${arg_key^^}"
            echo "Overriding $arg_key with $arg_data"
            export $arg_key="$arg_data"
            ;;
        *)
            args+=("$arg");;
    esac
    shift
done
set -- "${args[@]}"

if [[ $DEBUG == true ]] ; then
    set -x
fi

if [[ $ACCESS == "" ]] ; then
    ACCESS="--access=HOST"
fi

if [[ $IPADDR == "" ]] ; then
    gwdev=$(/sbin/ip -o -4 route show default |head -1 |awk '{print $5}')
    if [[ $gwdev ]]; then
        # First, advertise the address of the device with the default gateway
	IPADDR=$(/sbin/ip -o -4 addr show scope global dev "$gwdev" |head -1 |awk '{print $4}')
    else
        # Hmmm... we have no access to the Internet.  Pick an address with
        # global scope and hope for the best.
	IPADDR=$(/sbin/ip -o -4 addr show scope global |head -1 |awk '{print $4}')
    fi

    IPADDR="--admin-ip=$IPADDR"
fi

# Figure out what Linux distro we are running on.
export OS_TYPE= OS_VER= OS_NAME=

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_TYPE=${ID,,}
    OS_VER=${VERSION_ID,,}
elif [[ -f /etc/lsb-release ]]; then
    . /etc/lsb-release
    OS_VER=${DISTRIB_RELEASE,,}
    OS_TYPE=${DISTRIB_ID,,}
elif [[ -f /etc/centos-release || -f /etc/fedora-release || -f /etc/redhat-release ]]; then
    for rel in centos-release fedora-release redhat-release; do
        [[ -f /etc/$rel ]] || continue
        OS_TYPE=${rel%%-*}
        OS_VER="$(egrep -o '[0-9.]+' "/etc/$rel")"
        break
    done
    if [[ ! $OS_TYPE ]]; then
        echo "Cannot determine Linux version we are running on!"
        exit 1
    fi
elif [[ -f /etc/debian_version ]]; then
    OS_TYPE=debian
    OS_VER=$(cat /etc/debian_version)
elif [[ $(uname -s) == Darwin ]] ; then
    OS_TYPE=darwin
    OS_VER=$(sw_vers | grep ProductVersion | awk '{ print $2 }')
fi
OS_NAME="$OS_TYPE-$OS_VER"

case $OS_TYPE in
    centos|redhat|fedora) OS_FAMILY="rhel";;
    debian|ubuntu) OS_FAMILY="debian";;
    *) OS_FAMILY=$OS_TYPE;;
esac

# Detect when we are in a cloud
case $(sudo dmidecode -s bios-version) in
    '4.2.amazon' )
        CLOUD="--cloud=AWS"
        echo "Cloud Install Detected: Running in Amazon"
        ;;
    'Google' )
        CLOUD="--cloud=GOOGLE"
        echo "Cloud Install Detected: Running in Google"
        ;;
esac

#
# Functions that help validate or start things.
# 

validate_tools() {
    error_flag=0
    if [ "${BASH_VERSINFO}" -lt 4 ] ; then
        echo "Must have a bash version of 4 or higher"
        error_flag=1
    fi

    if [[ ! -e ~/.ssh/id_rsa ]] ; then
        echo "SSH key missing so we are adding one for you"
        echo "Hint: Copy your own key to ~/digitalrebar/deploy/compose/config-dir/api/config/ssh_keys/my_key.key before Rebar starts"
        ssh-keygen -t rsa -f ~/.ssh/id_rsa -P '' 2>/dev/null >/dev/null
    fi

    if ! which sudo &>/dev/null; then
	echo "Installing sudo ..."
        if [[ $OS_FAMILY == rhel ]] ; then
            yum install -y sudo 2>/dev/null >/dev/null
        elif [[ $OS_FAMILY == debian ]] ; then
            apt-get install -y sudo 2>/dev/null >/dev/null
            sudo updatedb 2>/dev/null >/dev/null
        fi

        if ! which sudo &>/dev/null; then
            echo "Please install sudo!"
            if [[ $(uname -s) == Darwin ]] ; then
                echo "Something like: brew install sudo"
            fi
            error_flag=1
        fi
    fi

    if ! which git &>/dev/null; then
	echo "Installing git ..."
        if [[ $OS_FAMILY == rhel ]] ; then
            sudo yum install -y git 2>/dev/null >/dev/null
        elif [[ $OS_FAMILY == debian ]] ; then
            sudo apt-get install -y git 2>/dev/null >/dev/null
            sudo updatedb 2>/dev/null >/dev/null
        fi

        if ! which git &>/dev/null; then
            echo "Please install git!"
            if [[ $(uname -s) == Darwin ]] ; then
                echo "Something like: brew install git"
            fi
            error_flag=1
        fi
    fi

    if [[ $OS_VER == 14.04 ]] ; then
        echo "Updating python to get one that does unicode correctly ..."
        sudo apt-get install -y software-properties-common 2>/dev/null >/dev/null
        sudo apt-add-repository -y ppa:fkrull/deadsnakes-python2.7 2>/dev/null >/dev/null
        sudo apt-get update -y 2>/dev/null >/dev/null
        sudo apt-get install -y python python-pycurl 2>/dev/null >/dev/null
        sudo updatedb 2>/dev/null >/dev/null
    fi

    if ! which ansible &>/dev/null; then
	echo "Installing ansible ..."
        if [[ $OS_FAMILY == rhel ]] ; then
            sudo yum -y install epel-release 2>/dev/null >/dev/null
            sudo yum install -y ansible python-netaddr 2>/dev/null >/dev/null
        elif [[ $OS_FAMILY == debian ]] ; then
            sudo apt-get install -y software-properties-common 2>/dev/null >/dev/null
            sudo apt-add-repository -y ppa:ansible/ansible 2>/dev/null >/dev/null
            sudo apt-get update -y 2>/dev/null >/dev/null
            sudo apt-get install -y ansible python-netaddr 2>/dev/null >/dev/null
            sudo updatedb 2>/dev/null >/dev/null
        fi

        if ! which ansible &>/dev/null; then
            echo "Please install Ansible!"
            if [[ $OS_FAMILY == darwin ]] ; then
                echo "Something like: brew install ansible or pip install ansible python-netaddr"
            fi
            error_flag=1
        fi
    fi

    if ! which curl &>/dev/null; then
	echo "Installing curl ..."
        if [[ $OS_FAMILY == rhel ]] ; then
            sudo yum install -y curl 2>/dev/null >/dev/null
        elif [[ $OS_FAMILY == debian ]] ; then
            sudo apt-get install -y curl 2>/dev/null >/dev/null
            sudo updatedb 2>/dev/null >/dev/null
        fi

        if ! which curl &>/dev/null; then
            echo "Please install curl!"
            if [[ $(uname -s) == Darwin ]] ; then
                echo "Something like: brew install curl"
            fi
            error_flag=1
        fi
    fi

    if ! which jq &>/dev/null; then
	echo "Installing jq ..."
        if [[ $OS_FAMILY == rhel ]] ; then
            sudo yum -y install epel-release 2>/dev/null >/dev/null
            sudo yum install -y jq 2>/dev/null >/dev/null
        elif [[ $OS_FAMILY == debian ]] ; then
            sudo apt-get install -y jq 2>/dev/null >/dev/null
            sudo updatedb 2>/dev/null >/dev/null
        else
            echo "Please install jq!"
            if [[ $(uname -s) == Darwin ]] ; then
                echo "Something like: brew install jq"
                error_flag=1
            fi
        fi
    fi

    if [[ $error_flag == 1 ]] ; then
        exit 1
    fi
}

rebar() {
    local rebar_cmd

    rebar_cmd=$(which rebar)
    if [[ $rebar_cmd == "" ]] ; then
        if [[ $(uname -s) == Darwin ]] ; then
            curl -so rebar https://s3-us-west-2.amazonaws.com/rebar-bins/darwin/amd64/rebar
        else
            curl -so rebar https://s3-us-west-2.amazonaws.com/rebar-bins/linux/amd64/rebar
        fi
        chmod +x ./rebar
    fi

    command rebar "$@"
}

validate_tools

if [[ ! -e 'digitalrebar' ]] ; then
    git clone -b NewCentos https://github.com/taliesins/digitalrebar
else
    echo "NOTE: Digital Rebar directory detected, NOT cloning or updating code."
fi

cd digitalrebar/deploy
./run-in-system.sh $ACCESS $IPADDR $CLOUD --deploy-admin=local $@
echo "!!! QUICK START REMINDER !!!"
echo "You must use the EXTERNAL IP ADDRESS (not the one shown above) to access Digital Rebar"
