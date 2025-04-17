#!/bin/bash

# Configuration
PORT=12345
DEFAULT_PSEUDO=$(whoami)
LOG_FILE="/tmp/chat_$(whoami).log"
HISTORY_FILE="$HOME/.chat_history"
PEERS_FILE="$HOME/.chat_peers"
VERSION="2.0"

# Vérifier si les fichiers nécessaires existent, sinon les créer
if [ ! -f "$HISTORY_FILE" ]; then
    touch "$HISTORY_FILE"
fi

if [ ! -f "$PEERS_FILE" ]; then
    touch "$PEERS_FILE"
fi

# Fonction pour obtenir l'adresse IP locale principale
get_local_ip() {
    local_ip=$(ip route get 8.8.8.8 2>/dev/null | head -1 | awk '{print $7}')
    if [ -z "$local_ip" ]; then
        local_ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$local_ip"
}

LOCAL_IP=$(get_local_ip)

# Fonction pour afficher l'aide
show_help() {
    echo "Chat P2P Multi-réseaux Shell Linux v$VERSION"
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help        Affiche cette aide"
    echo "  -p, --port NUM    Utilise le port spécifié (défaut: $PORT)"
    echo "  -n, --name PSEUDO Utilise le pseudo spécifié (défaut: $DEFAULT_PSEUDO)"
    echo ""
    echo "Commandes disponibles pendant l'exécution:"
    echo "  /quit             Quitte le chat"
    echo "  /users            Liste les utilisateurs actifs"
    echo "  /name PSEUDO      Change de pseudo"
    echo "  /history          Affiche l'historique des messages"
    echo "  /clear            Efface l'écran"
    echo "  /whisper PSEUDO   Envoie un message privé à un utilisateur"
    echo "  /connect IP:PORT  Se connecte à un pair distant"
    echo "  /disconnect IP    Supprime un pair distant"
    echo "  /peers            Liste les pairs connectés"
    exit 0
}

# Traitement des arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -n|--name)
            DEFAULT_PSEUDO="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Option inconnue: $1"
            show_help
            ;;
    esac
done

# Vérifier si netcat est installé
if ! command -v nc &> /dev/null; then
    echo "Netcat (nc) n'est pas installé. Veuillez l'installer pour utiliser ce script."
    exit 1
fi

# Vérifier si socat est installé pour le NAT traversal (optionnel mais recommandé)
if ! command -v socat &> /dev/null; then
    echo "Note: socat n'est pas installé. L'installation de socat peut améliorer la connectivité à travers les NAT."
    # Ce n'est pas critique, donc on continue
fi

# Afficher une bannière
echo "╔═════════════════════════════════════════════════╗"
echo "║    Chat P2P Multi-réseaux Shell Linux v$VERSION    ║"
echo "╚═════════════════════════════════════════════════╝"
echo "Connecté en tant que: $DEFAULT_PSEUDO"
echo "Adresse IP locale: $LOCAL_IP"
echo "Port d'écoute: $PORT"
echo "Tapez /help pour afficher les commandes disponibles"
echo "Tapez /connect IP:PORT pour vous connecter à un pair distant"
echo ""

# Vérifier si le port est déjà utilisé
if netstat -tuln | grep -q ":$PORT "; then
    echo "ERREUR: Le port $PORT est déjà utilisé."
    exit 1
fi

# Déclarer l'array associatif pour les pairs et utilisateurs actifs
declare -A PEERS
declare -A ACTIVE_USERS
ACTIVE_USERS["$DEFAULT_PSEUDO:$LOCAL_IP"]=$(date +%s)

# Charger les pairs existants à partir du fichier
if [ -s "$PEERS_FILE" ]; then
    while IFS= read -r line; do
        # Format: IP PORT
        peer_ip=$(echo "$line" | awk '{print $1}')
        peer_port=$(echo "$line" | awk '{print $2}')
        if [ ! -z "$peer_ip" ] && [ ! -z "$peer_port" ]; then
            PEERS["$peer_ip"]="$peer_port"
            echo "Pair chargé: $peer_ip:$peer_port"
        fi
    done < "$PEERS_FILE"
fi

# Fonction pour nettoyer à la sortie
cleanup() {
    echo -e "\nFermeture du chat..."
    # Informer tous les pairs que nous quittons
    for peer_ip in "${!PEERS[@]}"; do
        peer_port=${PEERS["$peer_ip"]}
        echo "SYS:LEAVE:$DEFAULT_PSEUDO:$LOCAL_IP" | nc -w 1 -u $peer_ip $peer_port &>/dev/null
    done
    # Tuer tous les processus en arrière-plan
    kill $(jobs -p) &>/dev/null 2>&1
    exit 0
}

# Capturer CTRL+C pour nettoyer
trap cleanup SIGINT SIGTERM

# Fonction pour envoyer un message à tous les pairs
broadcast_message() {
    local message="$1"
    for peer_ip in "${!PEERS[@]}"; do
        peer_port=${PEERS["$peer_ip"]}
        echo "$message" | nc -w 1 -u $peer_ip $peer_port &>/dev/null
    done
}

# Fonction pour envoyer un message
send_message() {
    local msg_type="$1"
    local destination="$2"
    local content="$3"
    
    case "$msg_type" in
        "MSG") # Message standard
            local message="MSG:$DEFAULT_PSEUDO:$LOCAL_IP:$content"
            broadcast_message "$message"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $DEFAULT_PSEUDO: $content" >> "$HISTORY_FILE"
            ;;
        "JOIN") # Notification d'arrivée
            local message="SYS:JOIN:$DEFAULT_PSEUDO:$LOCAL_IP"
            broadcast_message "$message"
            ;;
        "PM") # Message privé
            local dest_pseudo=$(echo "$destination" | cut -d':' -f1)
            local dest_ip=$(echo "$destination" | cut -d':' -f2)
            local message="PM:$DEFAULT_PSEUDO:$LOCAL_IP:$dest_pseudo:$content"
            
            # Envoyer le message privé directement à l'IP du destinataire
            for peer_ip in "${!PEERS[@]}"; do
                if [ "$peer_ip" = "$dest_ip" ]; then
                    peer_port=${PEERS["$peer_ip"]}
                    echo "$message" | nc -w 1 -u $peer_ip $peer_port &>/dev/null
                    echo -e "\033[35m[Privé à $dest_pseudo] $content\033[0m"
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - [Privé à $dest_pseudo] $content" >> "$HISTORY_FILE"
                    break
                fi
            done
            ;;
    esac
}

# Fonction pour ajouter un pair
add_peer() {
    local peer_info="$1"
    local peer_ip=$(echo "$peer_info" | cut -d':' -f1)
    local peer_port=$(echo "$peer_info" | cut -d':' -f2)
    
    if [ -z "$peer_ip" ] || [ -z "$peer_port" ]; then
        echo -e "\033[31mFormat incorrect. Utilisez: /connect IP:PORT\033[0m"
        return 1
    fi
    
    # Vérifier si le pair existe déjà
    if [ "${PEERS[$peer_ip]}" = "$peer_port" ]; then
        echo -e "\033[33mVous êtes déjà connecté à $peer_ip:$peer_port\033[0m"
        return 0
    fi
    
    # Essayer de se connecter au pair
    if echo "SYS:PING:$DEFAULT_PSEUDO:$LOCAL_IP:$PORT" | nc -w 3 -u $peer_ip $peer_port &>/dev/null; then
        PEERS["$peer_ip"]="$peer_port"
        
        # Sauvegarder le pair dans le fichier
        if ! grep -q "^$peer_ip $peer_port$" "$PEERS_FILE"; then
            echo "$peer_ip $peer_port" >> "$PEERS_FILE"
        fi
        
        echo -e "\033[32mConnecté avec succès à $peer_ip:$peer_port\033[0m"
        
        # Envoyer un message d'arrivée
        echo "SYS:JOIN:$DEFAULT_PSEUDO:$LOCAL_IP" | nc -w 1 -u $peer_ip $peer_port &>/dev/null
        
        return 0
    else
        echo -e "\033[31mImpossible de se connecter à $peer_ip:$peer_port\033[0m"
        return 1
    fi
}

# Fonction pour supprimer un pair
remove_peer() {
    local peer_ip="$1"
    
    if [ -z "$peer_ip" ]; then
        echo -e "\033[31mVeuillez spécifier une adresse IP\033[0m"
        return 1
    fi
    
    if [ -n "${PEERS[$peer_ip]}" ]; then
        unset PEERS["$peer_ip"]
        
        # Mettre à jour le fichier des pairs
        grep -v "^$peer_ip " "$PEERS_FILE" > "${PEERS_FILE}.tmp"
        mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
        
        echo -e "\033[32mLe pair $peer_ip a été supprimé\033[0m"
        
        # Supprimer les utilisateurs associés à cette IP
        for user_key in "${!ACTIVE_USERS[@]}"; do
            user_ip=$(echo "$user_key" | cut -d':' -f2)
            if [ "$user_ip" = "$peer_ip" ]; then
                unset ACTIVE_USERS["$user_key"]
            fi
        done
        
        return 0
    else
        echo -e "\033[31mLe pair $peer_ip n'existe pas\033[0m"
        return 1
    fi
}

# Fonction pour gérer les commandes
handle_command() {
    local cmd="$1"
    local args="${@:2}"
    
    case "$cmd" in
        "/quit")
            cleanup
            ;;
        "/help")
            echo -e "\033[33m--- Commandes disponibles ---\033[0m"
            echo -e "\033[33m/quit\033[0m - Quitte le chat"
            echo -e "\033[33m/users\033[0m - Liste les utilisateurs actifs"
            echo -e "\033[33m/name PSEUDO\033[0m - Change de pseudo"
            echo -e "\033[33m/history\033[0m - Affiche l'historique des messages"
            echo -e "\033[33m/clear\033[0m - Efface l'écran"
            echo -e "\033[33m/whisper PSEUDO MESSAGE\033[0m - Envoie un message privé"
            echo -e "\033[33m/connect IP:PORT\033[0m - Se connecte à un pair distant"
            echo -e "\033[33m/disconnect IP\033[0m - Supprime un pair distant"
            echo -e "\033[33m/peers\033[0m - Liste les pairs connectés"
            ;;
        "/users")
            echo -e "\033[33m--- Utilisateurs actifs ---\033[0m"
            
            # Filtrer les utilisateurs inactifs (plus de 5 minutes)
            current_time=$(date +%s)
            for user_key in "${!ACTIVE_USERS[@]}"; do
                last_seen=${ACTIVE_USERS["$user_key"]}
                user_pseudo=$(echo "$user_key" | cut -d':' -f1)
                user_ip=$(echo "$user_key" | cut -d':' -f2)
                
                if (( current_time - last_seen < 300 )); then
                    if [ "$user_pseudo" = "$DEFAULT_PSEUDO" ] && [ "$user_ip" = "$LOCAL_IP" ]; then
                        echo -e "👤 \033[32m$user_pseudo\033[0m (vous) @ $user_ip"
                    else
                        echo -e "👤 \033[32m$user_pseudo\033[0m @ $user_ip"
                    fi
                else
                    # Supprimer les utilisateurs inactifs depuis plus de 5 minutes
                    unset ACTIVE_USERS["$user_key"]
                fi
            done
            
            # Demander une mise à jour des utilisateurs actifs
            broadcast_message "SYS:PING:$DEFAULT_PSEUDO:$LOCAL_IP"
            ;;
        "/name")
            if [ -z "$args" ]; then
                echo -e "\033[31mErreur: Vous devez spécifier un pseudo\033[0m"
            else
                local old_pseudo="$DEFAULT_PSEUDO"
                DEFAULT_PSEUDO="$args"
                echo -e "\033[32mVotre pseudo a été changé de $old_pseudo à $DEFAULT_PSEUDO\033[0m"
                
                # Mettre à jour l'utilisateur local
                unset ACTIVE_USERS["$old_pseudo:$LOCAL_IP"]
                ACTIVE_USERS["$DEFAULT_PSEUDO:$LOCAL_IP"]=$(date +%s)
                
                # Informer les autres du changement
                broadcast_message "SYS:RENAME:$old_pseudo:$DEFAULT_PSEUDO:$LOCAL_IP"
            fi
            ;;
        "/history")
            echo -e "\033[33m--- Historique des messages ---\033[0m"
            tail -n 50 "$HISTORY_FILE"
            echo -e "\033[33m--- Fin de l'historique ---\033[0m"
            ;;
        "/clear")
            clear
            echo "╔═════════════════════════════════════════════════╗"
            echo "║    Chat P2P Multi-réseaux Shell Linux v$VERSION    ║"
            echo "╚═════════════════════════════════════════════════╝"
            echo "Connecté en tant que: $DEFAULT_PSEUDO"
            echo "Adresse IP locale: $LOCAL_IP"
            echo "Port d'écoute: $PORT"
            ;;
        "/whisper")
            local recipient=$(echo "$args" | awk '{print $1}')
            local message=$(echo "$args" | cut -d ' ' -f 2-)
            
            if [ -z "$recipient" ] || [ -z "$message" ]; then
                echo -e "\033[31mErreur: Format correct: /whisper PSEUDO MESSAGE\033[0m"
                return 1
            fi
            
            # Trouver l'IP associée au pseudo
            local recipient_ip=""
            for user_key in "${!ACTIVE_USERS[@]}"; do
                user_pseudo=$(echo "$user_key" | cut -d':' -f1)
                user_ip=$(echo "$user_key" | cut -d':' -f2)
                
                if [ "$user_pseudo" = "$recipient" ]; then
                    recipient_ip="$user_ip"
                    break
                fi
            done
            
            if [ -z "$recipient_ip" ]; then
                echo -e "\033[31mUtilisateur introuvable: $recipient\033[0m"
                return 1
            fi
            
            send_message "PM" "$recipient:$recipient_ip" "$message"
            ;;
        "/connect")
            add_peer "$args"
            ;;
        "/disconnect")
            remove_peer "$args"
            ;;
        "/peers")
            echo -e "\033[33m--- Pairs connectés ---\033[0m"
            if [ ${#PEERS[@]} -eq 0 ]; then
                echo -e "\033[33mAucun pair connecté\033[0m"
            else
                for peer_ip in "${!PEERS[@]}"; do
                    echo -e "🖧 \033[32m$peer_ip:${PEERS[$peer_ip]}\033[0m"
                done
            fi
            ;;
        *)
            echo -e "\033[31mCommande inconnue: $cmd\033[0m"
            echo -e "\033[31mTapez /help pour voir les commandes disponibles\033[0m"
            ;;
    esac
}

# Démarrer le récepteur en arrière-plan
{
    nc -u -l $PORT | while read line; do
        # Format attendu: TYPE:EMETTEUR:IP:CONTENU
        msg_type=$(echo "$line" | cut -d':' -f1)
        sender=$(echo "$line" | cut -d':' -f2)
        sender_ip=$(echo "$line" | cut -d':' -f3)
        
        # Mettre à jour la liste des utilisateurs actifs
        ACTIVE_USERS["$sender:$sender_ip"]=$(date +%s)
        
        case "$msg_type" in
            "MSG") # Message normal
                content=$(echo "$line" | cut -d':' -f4-)
                echo -e "\033[32m$sender:\033[0m $content"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - $sender: $content" >> "$HISTORY_FILE"
                ;;
            "SYS") # Message système
                sys_type=$(echo "$line" | cut -d':' -f2)
                
                case "$sys_type" in
                    "JOIN")
                        sys_name=$(echo "$line" | cut -d':' -f3)
                        sys_ip=$(echo "$line" | cut -d':' -f4)
                        
                        echo -e "\033[34m[Système] $sys_name@$sys_ip a rejoint le chat\033[0m"
                        ACTIVE_USERS["$sys_name:$sys_ip"]=$(date +%s)
                        
                        # Ajouter le pair s'il n'existe pas déjà
                        if [ -z "${PEERS[$sys_ip]}" ]; then
                            # Utiliser le port par défaut si non spécifié
                            PEERS["$sys_ip"]="$PORT"
                            # Sauvegarder le pair
                            if ! grep -q "^$sys_ip $PORT$" "$PEERS_FILE"; then
                                echo "$sys_ip $PORT" >> "$PEERS_FILE"
                            fi
                        fi
                        
                        # Répondre pour signaler notre présence
                        echo "SYS:ACTIVE:$DEFAULT_PSEUDO:$LOCAL_IP" | nc -w 1 -u $sys_ip $PORT &>/dev/null
                        ;;
                    "LEAVE")
                        sys_name=$(echo "$line" | cut -d':' -f3)
                        sys_ip=$(echo "$line" | cut -d':' -f4)
                        
                        echo -e "\033[34m[Système] $sys_name@$sys_ip a quitté le chat\033[0m"
                        unset ACTIVE_USERS["$sys_name:$sys_ip"]
                        ;;
                    "PING")
                        ping_name=$(echo "$line" | cut -d':' -f3)
                        ping_ip=$(echo "$line" | cut -d':' -f4)
                        ping_port=$(echo "$line" | cut -d':' -f5)
                        
                        # Si le port est spécifié, l'utiliser
                        if [ ! -z "$ping_port" ]; then
                            # Mettre à jour le port du pair
                            PEERS["$ping_ip"]="$ping_port"
                            # Mettre à jour le fichier des pairs
                            if grep -q "^$ping_ip " "$PEERS_FILE"; then
                                sed -i "s/^$ping_ip .*/$ping_ip $ping_port/" "$PEERS_FILE"
                            else
                                echo "$ping_ip $ping_port" >> "$PEERS_FILE"
                            fi
                        fi
                        
                        # Répondre au ping
                        echo "SYS:ACTIVE:$DEFAULT_PSEUDO:$LOCAL_IP" | nc -w 1 -u $ping_ip ${PEERS["$ping_ip"]} &>/dev/null
                        ;;
                    "ACTIVE")
                        active_name=$(echo "$line" | cut -d':' -f3)
                        active_ip=$(echo "$line" | cut -d':' -f4)
                        
                        # Mettre à jour la liste des utilisateurs actifs
                        ACTIVE_USERS["$active_name:$active_ip"]=$(date +%s)
                        
                        # Ajouter silencieusement le pair s'il n'existe pas
                        if [ -z "${PEERS[$active_ip]}" ]; then
                            PEERS["$active_ip"]="$PORT"
                            if ! grep -q "^$active_ip " "$PEERS_FILE"; then
                                echo "$active_ip $PORT" >> "$PEERS_FILE"
                            fi
                        fi
                        ;;
                    "RENAME")
                        old_name=$(echo "$line" | cut -d':' -f3)
                        new_name=$(echo "$line" | cut -d':' -f4)
                        rename_ip=$(echo "$line" | cut -d':' -f5)
                        
                        echo -e "\033[34m[Système] $old_name@$rename_ip a changé son pseudo en $new_name\033[0m"
                        unset ACTIVE_USERS["$old_name:$rename_ip"]
                        ACTIVE_USERS["$new_name:$rename_ip"]=$(date +%s)
                        ;;
                esac
                ;;
            "PM") # Message privé
                pm_sender=$(echo "$line" | cut -d':' -f2)
                pm_sender_ip=$(echo "$line" | cut -d':' -f3)
                pm_target=$(echo "$line" | cut -d':' -f4)
                pm_content=$(echo "$line" | cut -d':' -f5-)
                
                # Afficher seulement si le message privé est pour nous
                if [ "$pm_target" = "$DEFAULT_PSEUDO" ]; then
                    echo -e "\033[35m[Privé de $pm_sender@$pm_sender_ip] $pm_content\033[0m"
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - [Privé de $pm_sender] $pm_content" >> "$HISTORY_FILE"
                    ACTIVE_USERS["$pm_sender:$pm_sender_ip"]=$(date +%s)
                    
                    # Ajouter silencieusement le pair s'il n'existe pas
                    if [ -z "${PEERS[$pm_sender_ip]}" ]; then
                        PEERS["$pm_sender_ip"]="$PORT"
                        if ! grep -q "^$pm_sender_ip " "$PEERS_FILE"; then
                            echo "$pm_sender_ip $PORT" >> "$PEERS_FILE"
                        fi
                    fi
                fi
                ;;
        esac
    done
} &

# Fonction pour vérifier périodiquement les pairs actifs
{
    while true; do
        sleep 60  # Vérification toutes les minutes
        
        # Envoyer un ping à tous les pairs
        for peer_ip in "${!PEERS[@]}"; do
            peer_port=${PEERS["$peer_ip"]}
            echo "SYS:PING:$DEFAULT_PSEUDO:$LOCAL_IP" | nc -w 1 -u $peer_ip $peer_port &>/dev/null
        done
    done
} &

# Si nous avons des pairs chargés, envoyer un message d'arrivée
if [ ${#PEERS[@]} -gt 0 ]; then
    send_message "JOIN" "" ""
fi

# Message initial d'information
echo -e "\033[34m[Système] Pour vous connecter à un autre utilisateur, utilisez la commande /connect IP:PORT\033[0m"
echo -e "\033[34m[Système] Votre IP est $LOCAL_IP et votre port est $PORT\033[0m"

# Boucle principale pour l'entrée utilisateur
while true; do
    read -e input
    
    # Ignorer les lignes vides
    if [ -z "$input" ]; then
        continue
    fi
    
    # Vérifier si c'est une commande
    if [[ "$input" == /* ]]; then
        handle_command $input
    else
        # Envoyer comme message normal
        send_message "MSG" "" "$input"
    fi
done
