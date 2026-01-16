#!/bin/bash
# LLDPq Authentication Manager - Enable/Disable web interface authentication
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License

echo "🔐 LLDPq Authentication Manager"
echo "==============================="

# Check if running with sudo/root permissions for nginx config
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script needs to be run as root (use sudo)"
   echo "   sudo auth-lldpq"
   exit 1
fi

# Check if nginx is installed
if ! command -v nginx &> /dev/null; then
    echo "❌ Nginx is not installed. Please install nginx first."
    exit 1
fi

echo ""
echo "[1] Checking current authentication status..."

# Check current status
if grep -q "^[[:space:]]*auth_basic " /etc/nginx/sites-available/lldpq; then
    current_status="ENABLED"
    echo "✅ Authentication is currently ENABLED"
else
    current_status="DISABLED"
    echo "ℹ️  Authentication is currently DISABLED"
fi

echo ""
echo "What would you like to do?"
echo "  [1] Enable authentication (secure with username/password)"
echo "  [2] Disable authentication (open access)"
echo "  [3] Exit without changes"
echo ""
read -p "Choose option [1-3]: " -n 1 -r choice
echo ""

case $choice in
    1)
        if [[ "$current_status" == "ENABLED" ]]; then
            echo ""
            echo "⚠️  Authentication is already enabled."
            read -p "Do you want to update the credentials? [y/N]: " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "❌ Operation cancelled"
                exit 0
            fi
        fi
        
        echo ""
        echo "🔒 ENABLING AUTHENTICATION"
        echo "=========================="
        
        # Prompt for username
        read -p "Enter admin username [admin]: " USERNAME
        USERNAME=${USERNAME:-admin}
        
        # Prompt for password
        while true; do
            read -s -p "Enter password for '$USERNAME': " PASSWORD
            echo ""
            read -s -p "Confirm password: " PASSWORD_CONFIRM
            echo ""
            
            if [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]]; then
                if [[ ${#PASSWORD} -lt 6 ]]; then
                    echo "❌ Password must be at least 6 characters"
                    continue
                fi
                break
            else
                echo "❌ Passwords do not match. Please try again."
            fi
        done
        
        echo ""
        echo "[2] Creating password file..."
        
        # Create htpasswd file
        if command -v htpasswd &> /dev/null; then
            htpasswd -cb /etc/nginx/.htpasswd "$USERNAME" "$PASSWORD"
        elif command -v openssl &> /dev/null; then
            # Fallback to openssl if htpasswd not available
            echo "$USERNAME:$(openssl passwd -apr1 "$PASSWORD")" > /etc/nginx/.htpasswd
        else
            echo "❌ Neither htpasswd nor openssl found. Please install apache2-utils or openssl."
            exit 1
        fi
        
        chmod 644 /etc/nginx/.htpasswd
        echo "✅ Password file created: /etc/nginx/.htpasswd"
        
        echo ""
        echo "[3] Enabling authentication in nginx config..."
        
        # Enable auth in nginx config
        sed -i 's/^[[:space:]]*#[[:space:]]*auth_basic/            auth_basic/' /etc/nginx/sites-available/lldpq
        sed -i 's/^[[:space:]]*#[[:space:]]*auth_basic_user_file/            auth_basic_user_file/' /etc/nginx/sites-available/lldpq
        
        echo "✅ Authentication enabled in nginx config"
        
        echo ""
        echo "[4] Testing nginx configuration..."
        if nginx -t; then
            echo "✅ Nginx configuration is valid"
            
            echo ""
            echo "[5] Reloading nginx..."
            systemctl reload nginx
            echo "✅ Nginx reloaded successfully"
            
            echo ""
            echo "🎉 Authentication ENABLED successfully!"
            echo ""
            echo "Access details:"
            echo "  • URL: http://$(hostname -I | awk '{print $1}')"
            echo "  • Username: $USERNAME"
            echo "  • Password: [the one you entered]"
            echo ""
            echo "All web pages now require authentication."
            
        else
            echo "❌ Nginx configuration test failed"
            echo "Rolling back changes..."
            sed -i 's/^[[:space:]]*auth_basic/            # auth_basic/' /etc/nginx/sites-available/lldpq
            sed -i 's/^[[:space:]]*auth_basic_user_file/            # auth_basic_user_file/' /etc/nginx/sites-available/lldpq
            exit 1
        fi
        ;;
        
    2)
        if [[ "$current_status" == "DISABLED" ]]; then
            echo ""
            echo "ℹ️  Authentication is already disabled."
            exit 0
        fi
        
        echo ""
        echo "🔓 DISABLING AUTHENTICATION"
        echo "==========================="
        
        read -p "Are you sure you want to disable authentication? [y/N]: " -n 1 -r
        echo ""
        
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "❌ Operation cancelled"
            exit 0
        fi
        
        echo ""
        echo "[2] Disabling authentication in nginx config..."
        
        # Disable auth in nginx config
        sed -i 's/^[[:space:]]*auth_basic/            # auth_basic/' /etc/nginx/sites-available/lldpq
        sed -i 's/^[[:space:]]*auth_basic_user_file/            # auth_basic_user_file/' /etc/nginx/sites-available/lldpq
        
        echo "✅ Authentication disabled in nginx config"
        
        echo ""
        echo "[3] Testing nginx configuration..."
        if nginx -t; then
            echo "✅ Nginx configuration is valid"
            
            echo ""
            echo "[4] Reloading nginx..."
            systemctl reload nginx
            echo "✅ Nginx reloaded successfully"
            
            echo ""
            echo "[5] Cleaning up password file..."
            if [[ -f "/etc/nginx/.htpasswd" ]]; then
                read -p "Remove password file? (keeps credentials for re-enabling) [y/N]: " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    rm -f /etc/nginx/.htpasswd
                    echo "✅ Password file removed"
                else
                    echo "ℹ️  Password file kept for future use"
                fi
            fi
            
            echo ""
            echo "🎉 Authentication DISABLED successfully!"
            echo ""
            echo "Access details:"
            echo "  • URL: http://$(hostname -I | awk '{print $1}')"
            echo "  • No authentication required"
            echo ""
            echo "All web pages are now open access."
            
        else
            echo "❌ Nginx configuration test failed"
            echo "Rolling back changes..."
            sed -i 's/^[[:space:]]*#[[:space:]]*auth_basic/            auth_basic/' /etc/nginx/sites-available/lldpq
            sed -i 's/^[[:space:]]*#[[:space:]]*auth_basic_user_file/            auth_basic_user_file/' /etc/nginx/sites-available/lldpq
            exit 1
        fi
        ;;
        
    3)
        echo ""
        echo "❌ No changes made. Exiting..."
        exit 0
        ;;
        
    *)
        echo ""
        echo "❌ Invalid option. Please choose 1, 2, or 3."
        exit 1
        ;;
esac

echo ""
echo "To change authentication settings later, run:"
echo "  cd ~/lldpq && sudo ./webauth.sh"