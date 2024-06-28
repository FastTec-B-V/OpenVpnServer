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

read -p "Enter your server's IP address: " ip
ip_ok=$(validate_ip "$ip")
while [[ $ip_ok -ne 0 ]]; do
    echo "Invalid IP address."
    read -p "Enter your server's IP address: " ip
    ip_ok=$(validate_ip "$ip")
done

read -p "Enter SSH port [default is 22]: " ssh_port
ssh_port=${ssh_port:-22}
port_ok=$(validate_port "$ssh_port")
while [[ $port_ok -ne 0 ]]; do
    echo "Invalid port number."
    read -p "Enter SSH port [default is 22]: " ssh_port
    ssh_port=${ssh_port:-22}
    port_ok=$(validate_port "$ssh_port")
done

read -p "Enter SSH password: " ssh_password
echo

read -p "Enter username [default is root]: " username
username=${username:-root}

read -p "Enter protocol (1 for udp, 0 for tcp) [default is udp]: " proto_index
proto_index=${proto_index:-1}
until [[ "$proto_index" =~ ^[01]$ ]]; do
    echo "$proto_index: invalid selection."
    read -p "Enter protocol (1 for udp, 0 for tcp) [default is udp]: " proto_index
    proto_index=${proto_index:-1}
done
if [[ $proto_index -eq 1 ]]; then proto='udp'; else proto='tcp'; fi

read -p "Enter port number [default is 1194]: " port
port=${port:-1194}
port_ok=$(validate_port "$port")
while [[ $port_ok -ne 0 ]]; do
    echo "Invalid port number."
    read -p "Enter port number [default is 1194]: " port
    port=${port:-1194}
    port_ok=$(validate_port "$port")
done

read -p "Is your server accessible with 'ssh_key' access key? [y/n]: " access
until [[ "$access" =~ ^[yYnN]$ ]]; do
    echo "$access: invalid selection."
    read -p "Is your server accessible with 'ssh_key' access key? [y/n]: " access
done

if [[ "$access" =~ ^[nN]$ ]]; then
    sshpass -p "$ssh_password" ssh-copy-id -o StrictHostKeyChecking=no -p $ssh_port "$username@$ip"
fi

echo -e "\n====== Uploading necessary files ======\n"
cp openvpn_config_files/server-template.conf openvpn_config_files/server.conf
sed -i'' -e "s/{proto}/$proto/" openvpn_config_files/server.conf
sed -i'' -e "s/{port}/$port/" openvpn_config_files/server.conf
sed -i'' -e "s/{een}/$proto_index/" openvpn_config_files/server.conf
sshpass -p "$ssh_password" scp -rp -P $ssh_port -o "StrictHostKeyChecking no" openvpn_config_files/ "$username@$ip:~/"
rm openvpn_config_files/server.conf
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
    sed -i'' -e "s/{interface}/$interface/" openvpn_config_files/before.rules
    yes | sudo cp -rf openvpn_config_files/before.rules /etc/ufw/before.rules
    yes | sudo cp -rf openvpn_config_files/ufw /etc/default/ufw
    yes | sudo cp -rf openvpn_config_files/sysctl.conf /etc/sysctl.conf
    echo -e "done\n"

    echo "====== Copying OpenVPN server files ======"
    sudo cp -rf openvpn_config_files/{ca.crt,dh.pem,server.conf,server.crt,server.key,ta.key} /etc/openvpn/
    echo -e "done\n"

    echo "====== Configuring firewall ======"
    sudo ufw disable
    sudo ufw allow "$port/$proto"
    sudo ufw allow OpenSSH
	sudo ufw allow ssh
    echo -e "done\n"

    echo "====== Starting OpenVPN ======"
    sudo systemctl start openvpn@server
    sudo systemctl enable openvpn@server
    sudo systemctl status openvpn@server
    echo -e "done\n"

    echo "Rebooting server..."
    echo "y" | sudo ufw enable & sleep 3; sudo reboot
END

echo "====== Creating ovpn file ======"
read -p "Enter file name for this server: " filename
while [[ ${#filename} -eq 0 ]]; do
    echo "File name cannot be empty!"
    read -p "Enter file name for this server: " filename
done

cp openvpn_config_files/template.ovpn "ovpn_files/$filename.ovpn"
sed -i'' -e "s/{ip}/$ip/" "ovpn_files/$filename.ovpn"
sed -i'' -e "s/{proto}/$proto/" "ovpn_files/$filename.ovpn"
sed -i'' -e "s/{port}/$port/" "ovpn_files/$filename.ovpn"
echo "Config file created successfully. You can find it in the ovpn_files folder. Copy or add it to your host."
read -n 1 -s -r -p "Press any key to exit"
