#!/bin/bash

# Fonction de log
# On récupère la date actuelle et le message à logger
# On log le message dans un fichier de log
function log {
    echo "$(date) - $1" >> "$sysconfig_dir/routes.log"
}

# Fonction de vérification des droits root
# Si l'utilisateur n'est pas root, on arrête le script
function check_root {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit 1
    fi
}

# Fonction de vérification de la version de Bash
function check_bashv {
    # Extract the major version of Bash
    local major_version
    major_version=$(bash --version | head -n1 | sed 's/^.* version \([0-9]*\)\..*$/\1/')

    # Check if the major version is 3 or greater
    if [ "$major_version" -ge 3 ]; then
        log "Bash version is 3 or superior, continuing..."
    else
        log "Bash version is less than 3, terminating program..."
        exit 1
    fi
}

# Fonction de vérification du fichier de fin d'exécution du script
# Si le fichier existe, on arrête le script
# Sinon, on continue
function check_exec {
    if [[ $created_routes -ne 0 ]]; then
        log "Routes already created, exiting."
        exit 1
    fi
}

# Fonction de vérification si le script est déjà dans le crontab
function check_cronned {
    if [ "$cronned" -eq 1 ]; then
        log "Script is cronned, continuing without adding it back..."
    else
        log "Script is not cronned, adding it and changing configuration..."
        (crontab -l; echo "@reboot $sysconfig_dir/${0##*/}") | crontab -
        change_value "cronned" 1
    fi
}

# Fonction de récupération des IPs des différentes interfaces
# On récupère les IPs des interfaces, on split la ligne pour récupérer l'IP
# On vérifie que l'interface n'est pas la loopback
# On ajoute l'IP à un tableau
# On retourne le tableau au script principal
function get_ips {
    local array_ip=()
    while read -r line ; do
        IFS=' ' read -r -a array <<< "$line"
        if [[ ${array[1]} != "lo" ]]; then
            array_ip+=("${array[3]}")
        fi
    done < <(ip -o -4 addr show)
    echo "${array_ip[@]}"
}

# Fonction de calcul de la gateway associée à une IP (Convention de nommage en x.x.x.1)
# On récupère l'IP, on la split en 4 parties
# On remplace la dernière partie par 1
# On reconstitue l'IP
# On retourne l'IP au script principal
function calculate_gateway {
    local ip2calc="$1"
    local ipGw=""

    IFS='.' read -r -a ip_parts <<< "$ip2calc"
    ip_parts[3]=1
    ipGw="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.${ip_parts[3]}"

    echo "$ipGw"
}

# Fonction de changement de valeur dans un fichier de configuration
function change_value {
    local file="$config_file"
    local key="$1"
    local value="$2"

    if ! grep -q "^$key=" "$file"; then
        echo "$key=$value" >> "$file"
    else
        sed -i "s/^\($key=\).*/\1$value/" "$file"
    fi
}

# Fonction de création de route
# On récupère le type de route (default ou remote), la gateway distante et le subnet
# On crée la route en fonction du type
# On log la commande
function create_route {
    local type="$1"
    local gw_remote="$2"
    local subnet="$3"

    if [[ $type == "default" ]]; then
        log "ip route add default via $gw_remote metric 10"
        ip route add default via "$gw_remote" metric 10
    elif [[ $type == "remote" ]]; then
        log "ip route add $subnet via $gw_remote metric 20"
        ip route add "$subnet" via "$gw_remote" metric 20
    else
        log "Unexpected route type, aborting program."
        exit 1
    fi
}

# Fonction principale
function main {
    # Définition des regex pour les adresses IP
    local private_cidr_regex='^(10\..*|192\.168\..*|172\.1[6-9]\..*|172\.2[0-9]\..*|172\.3[0-1]\..*)'
    local any_cidr_regex='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\/([0-9]|[1-2][0-9]|3[0-2]))$'

    # Définition du nombre de gateways calculés
    local nbr_IP_prv=0
    local nbr_IP_pub=0

    # Définition de cette gateway calculée
    local remote_gateway=""
    # Définition de la gateway publique
    local public_gateway=""
    # Définition de si il y a des réseaux distants...
    local array_ip=()
    local nbRoutes=0

    # On récupère les IPs des interfaces
    read -r -a array_ip < <(get_ips)

    # On parcourt les IPs pour les traiter
    for ip in "${array_ip[@]}"; do
        if [[ $ip == 127.0.0.1* ]]; then
            log "Found localhost interface, skipping..."
        elif  [[ $ip =~ $private_cidr_regex ]]; then
            log "Found private IP $ip"
            if [[ $nbr_IP_prv -eq 0 ]]; then
                remote_gateway=$(calculate_gateway "$ip")
                nbr_IP_prv=$((nbr_IP_prv + 1))
            else
                log "Multiple private IPs found, aborting program..."
                exit 1
            fi
        elif [[ $ip =~ $any_cidr_regex ]]; then
            log "Found public IP $ip"
            if [[ $nbr_IP_pub -eq 0 ]]; then
                public_gateway=$(calculate_gateway "$ip")
                nbr_IP_pub=$((nbr_IP_pub + 1))
            else
                log "Multiple public IPs found, aborting program..."
                exit 1
            fi
        else
            log "Unexpected IP found: $ip, terminating program..."
            exit 1
        fi
    done

    if [[ $nbr_IP_pub -eq 1 && $nbr_IP_prv -eq 1 ]]; then
        create_route default "$public_gateway"
        nbRoutes=$((nbRoutes + 1))
    else
        log "No public or no private IP found, terminating program..."
        exit 1
    fi

    # On crée les routes pour les réseaux distants
    if [[ -f $remote_subnet_conf ]]; then
        log "Last stored gateway: $remote_gateway"
        while IFS= read -r subnetline; do
            log "Found remote subnet $subnetline"
            if [[ ! "$subnetline" =~ $private_cidr_regex ]]; then
                log "$subnetline is not a private IP address, aborting program."
                exit 1
            fi
            create_route remote "$remote_gateway" "$subnetline"
            nbRoutes=$((nbRoutes + 1))
        done < "$remote_subnet_conf"
    fi

    # On crée le fichier de vérification de pré-exécution des routes
    if [[ $nbRoutes -eq 0 ]]; then
        log "Nothing created, just calculated gateways..."
        log "No routes created, terminating program..."
        exit 0
    elif [[ $nbRoutes -gt 0 ]]; then
        log "Routes created, editing config and leaving..."
        change_value "created_routes" 1
        exit 0
    else
        log "Uncaught error, terminating program..."
        exit 1
    fi
}

# Définition des variables globales
sysconfig_dir="/etc/routing"
if [ ! -d "$sysconfig_dir" ]; then
    mkdir -p "$sysconfig_dir"
fi

config_file="$sysconfig_dir/config"
source "$config_file" # Chargement de la config

# Exécution des fonctions de vérification et du script principal
check_root
check_bashv
check_exec
check_cronned

main
