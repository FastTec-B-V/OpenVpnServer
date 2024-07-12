#!/bin/bash

validate_ip() {
    local ip=$1
    local stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    echo $stat
}

validate_port() {
    local port=$1
    if ! [[ $port =~ ^[0-9]+$ ]]; then
        echo 1
        return
    fi
    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        echo 1
        return
    fi
    echo 0
}

usage() {
    echo "Usage: $0 --ip=<ip_address> --ssh-port=<ssh_port> --ssh-password=<ssh_password> --username=<username> --protocol=<protocol> --port=<port> --access=<access> --filename=<filename>"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ip=*)
            ip="${1#*=}"
            ;;
        --ssh-port=*)
            ssh_port="${1#*=}"
            ;;
        --ssh-password=*)
            ssh_password="${1#*=}"
            ;;
        --username=*)
            username="${1#*=}"
            ;;
        --protocol=*)
            proto_index="${1#*=}"
            ;;
        --port=*)
            port="${1#*=}"
            ;;
        --access=*)
            access="${1#*=}"
            ;;
        --filename=*)
            filename="${1#*=}"
            ;;
        *)
            usage
            ;;
    esac
    shift
done

# Validate inputs
if [[ -z "$ip" || -z "$ssh_port" || -z "$ssh_password" || -z "$username" || -z "$proto_index" || -z "$port" || -z "$access" || -z "$filename" ]]; then
    usage
fi

ip_ok=$(validate_ip "$ip")
if [[ $ip_ok -ne 0 ]]; then
    echo "Invalid IP address."
    exit 1
fi

port_ok=$(validate_port "$ssh_port")
if [[ $port_ok -ne 0 ]]; then
    echo "Invalid SSH port number."
    exit 1
fi

if [[ "$proto_index" =~ ^[01]$ ]]; then
    if [[ $proto_index -eq 1 ]]; then proto='udp'; else proto='tcp'; fi
else
    echo "Invalid protocol. Use 1 for udp, 0 for tcp."
    exit 1
fi

port_ok=$(validate_port "$port")
if [[ $port_ok -ne 0 ]]; then
    echo "Invalid port number."
    exit 1
fi

if [[ ! "$access" =~ ^[yYnN]$ ]]; then
    echo "Invalid access choice. Use 'y' or 'n'."
    exit 1
fi

if [[ "$access" =~ ^[nN]$ ]]; then
    sshpass -p "$ssh_password" ssh-copy-id -o StrictHostKeyChecking=no -p $ssh_port "$username@$ip"
fi

echo -e "\n====== Uploading necessary files ======\n"
cp /root/OpenVpnServer/openvpn_config_files/server-template.conf /root/OpenVpnServer/openvpn_config_files/server.conf
sed -i'' -e "s/{proto}/$proto/" /root/OpenVpnServer/openvpn_config_files/server.conf
sed -i'' -e "s/{port}/$port/" /root/OpenVpnServer/openvpn_config_files/server.conf
sed -i'' -e "s/{een}/$proto_index/" /root/OpenVpnServer/openvpn_config_files/server.conf
sshpass -p "$ssh_password" scp -rp -P $ssh_port -o "StrictHostKeyChecking no" /root/OpenVpnServer/openvpn_config_files/ "$username@$ip:~/"
rm /root/OpenVpnServer/openvpn_config_files/server.conf
echo -e "done\n"

interface=$(sshpass -p "$ssh_password" ssh -p $ssh_port "$username@$ip" ". /etc/profile && ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)'")
sshpass -p "$ssh_password" ssh -p $ssh_port "$username@$ip" << END
    echo -e "==== Removing old instances ===="
    yes | sudo apt remove openvpn
    sudo rm -r /etc/openvpn
    echo -e "done\n"

    echo "====== Installing OpenVPN ======"
    sudo apt update
    sudo apt install -y unzip
    sudo apt install -y openvpn ufw
    echo -e "done\n"

    echo "====== Configuring system ======"
    cd ~/
    sed -i'' -e "s/{interface}/$interface/" /root/OpenVpnServer/openvpn_config_files/before.rules
    yes | sudo cp -rf /root/OpenVpnServer/openvpn_config_files/before.rules /etc/ufw/before.rules
    yes | sudo cp -rf /root/OpenVpnServer/openvpn_config_files/ufw /etc/default/ufw
    yes | sudo cp -rf /root/OpenVpnServer/openvpn_config_files/sysctl.conf /etc/sysctl.conf
    echo -e "done\n"

    echo "====== Copying OpenVPN server files ======"
    sudo cp -rf /root/OpenVpnServer/openvpn_config_files/{ca.crt,dh.pem,server.conf,server.crt,server.key,ta.key} /etc/openvpn/
    echo -e "done\n"

    echo "====== Configuring firewall ======"
    sudo ufw disable
    echo -e "done\n"

    echo "====== Starting OpenVPN ======"
    sudo systemctl start openvpn@server
    sudo systemctl enable openvpn@server
    sudo systemctl status openvpn@server
    echo -e "done\n"

    echo "Rebooting server..."
    echo "y" | sudo ufw disable & sleep 3; sudo reboot
END

echo "====== Creating ovpn file ======"
cp /root/OpenVpnServer/openvpn_config_files/template.ovpn "/root/OpenVpnServer/ovpn_files/$filename.ovpn"
sed -i'' -e "s/{ip}/$ip/" "/root/OpenVpnServer/ovpn_files/$filename.ovpn"
sed -i'' -e "s/{proto}/$proto/" "/root/OpenVpnServer/ovpn_files/$filename.ovpn"
sed -i'' -e "s/{port}/$port/" "/root/OpenVpnServer/ovpn_files/$filename.ovpn"
echo "Config file created successfully. You can find it in the ovpn_files folder. Copy or add it to your host."
read -n 1 -s -r -p "Press any key to exit"
