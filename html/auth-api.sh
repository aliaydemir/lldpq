#!/bin/bash
# LLDPq Authentication API
# Handles login, logout, session management, and password changes

# Configuration
USERS_FILE="/etc/lldpq-users.conf"
SESSIONS_DIR="/var/lib/lldpq/sessions"
SESSION_TIMEOUT=28800  # 8 hours in seconds
REMEMBER_TIMEOUT=604800  # 7 days in seconds

# Ensure sessions directory exists
mkdir -p "$SESSIONS_DIR" 2>/dev/null
chmod 700 "$SESSIONS_DIR" 2>/dev/null

# Get action from query string
ACTION=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')

# Read POST data if present
if [ "$REQUEST_METHOD" = "POST" ]; then
    read -n "$CONTENT_LENGTH" POST_DATA
fi

# Function to get POST parameter
get_post_param() {
    echo "$POST_DATA" | tr '&' '\n' | grep "^$1=" | cut -d'=' -f2 | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))"
}

# Function to generate random token
generate_token() {
    openssl rand -hex 32
}

# Function to hash password
hash_password() {
    echo -n "$1" | openssl dgst -sha256 | awk '{print $2}'
}

# Function to get cookie
get_cookie() {
    echo "$HTTP_COOKIE" | tr ';' '\n' | grep "lldpq_session=" | cut -d'=' -f2 | tr -d ' '
}

# Function to validate session
validate_session() {
    local token="$1"
    local session_file="$SESSIONS_DIR/$token"
    
    if [ -z "$token" ] || [ ! -f "$session_file" ]; then
        return 1
    fi
    
    local expiry=$(head -1 "$session_file")
    local now=$(date +%s)
    
    if [ "$now" -gt "$expiry" ]; then
        rm -f "$session_file"
        return 1
    fi
    
    return 0
}

# Function to get session info
get_session_info() {
    local token="$1"
    local session_file="$SESSIONS_DIR/$token"
    
    if [ -f "$session_file" ]; then
        tail -n +2 "$session_file"
    fi
}

# Function to verify user credentials
verify_credentials() {
    local username="$1"
    local password="$2"
    
    if [ ! -f "$USERS_FILE" ]; then
        return 1
    fi
    
    local stored_hash=$(grep "^$username:" "$USERS_FILE" | cut -d':' -f2)
    local input_hash=$(hash_password "$password")
    
    if [ -z "$stored_hash" ]; then
        return 1
    fi
    
    if [ "$stored_hash" = "$input_hash" ]; then
        return 0
    fi
    
    return 1
}

# Function to get user role
get_user_role() {
    local username="$1"
    grep "^$username:" "$USERS_FILE" | cut -d':' -f3
}

# Clean expired sessions
clean_sessions() {
    local now=$(date +%s)
    for session_file in "$SESSIONS_DIR"/*; do
        if [ -f "$session_file" ]; then
            local expiry=$(head -1 "$session_file" 2>/dev/null)
            if [ -n "$expiry" ] && [ "$now" -gt "$expiry" ]; then
                rm -f "$session_file"
            fi
        fi
    done
}

# Clean sessions occasionally (1 in 10 requests)
if [ $((RANDOM % 10)) -eq 0 ]; then
    clean_sessions
fi

# Output JSON header
json_response() {
    echo "Content-Type: application/json"
    echo ""
    echo "$1"
}

# Handle actions
case "$ACTION" in
    login)
        USERNAME=$(get_post_param "username")
        PASSWORD=$(get_post_param "password")
        REMEMBER=$(get_post_param "remember")
        
        if verify_credentials "$USERNAME" "$PASSWORD"; then
            TOKEN=$(generate_token)
            ROLE=$(get_user_role "$USERNAME")
            
            if [ "$REMEMBER" = "true" ]; then
                EXPIRY=$(($(date +%s) + REMEMBER_TIMEOUT))
                COOKIE_EXPIRY="Max-Age=$REMEMBER_TIMEOUT;"
            else
                EXPIRY=$(($(date +%s) + SESSION_TIMEOUT))
                COOKIE_EXPIRY=""
            fi
            
            # Create session file
            echo "$EXPIRY" > "$SESSIONS_DIR/$TOKEN"
            echo "$USERNAME" >> "$SESSIONS_DIR/$TOKEN"
            echo "$ROLE" >> "$SESSIONS_DIR/$TOKEN"
            
            # Set cookie and return success
            echo "Content-Type: application/json"
            echo "Set-Cookie: lldpq_session=$TOKEN; Path=/; HttpOnly; SameSite=Strict; $COOKIE_EXPIRY"
            echo ""
            echo "{\"success\": true, \"username\": \"$USERNAME\", \"role\": \"$ROLE\"}"
        else
            json_response '{"success": false, "error": "Invalid username or password"}'
        fi
        ;;
        
    logout)
        TOKEN=$(get_cookie)
        if [ -n "$TOKEN" ]; then
            rm -f "$SESSIONS_DIR/$TOKEN"
        fi
        
        echo "Content-Type: application/json"
        echo "Set-Cookie: lldpq_session=; Path=/; HttpOnly; Max-Age=0"
        echo ""
        echo '{"success": true}'
        ;;
        
    check)
        TOKEN=$(get_cookie)
        
        if validate_session "$TOKEN"; then
            INFO=$(get_session_info "$TOKEN")
            USERNAME=$(echo "$INFO" | head -1)
            ROLE=$(echo "$INFO" | tail -1)
            json_response "{\"authenticated\": true, \"username\": \"$USERNAME\", \"role\": \"$ROLE\"}"
        else
            json_response '{"authenticated": false}'
        fi
        ;;
        
    change-password)
        TOKEN=$(get_cookie)
        
        if ! validate_session "$TOKEN"; then
            json_response '{"success": false, "error": "Not authenticated"}'
            exit 0
        fi
        
        INFO=$(get_session_info "$TOKEN")
        CURRENT_USER=$(echo "$INFO" | head -1)
        CURRENT_ROLE=$(echo "$INFO" | tail -1)
        
        # Only admin can change passwords
        if [ "$CURRENT_ROLE" != "admin" ]; then
            json_response '{"success": false, "error": "Permission denied"}'
            exit 0
        fi
        
        TARGET_USER=$(get_post_param "target_user")
        NEW_PASSWORD=$(get_post_param "new_password")
        
        # Validate target user exists
        if ! grep -q "^$TARGET_USER:" "$USERS_FILE"; then
            json_response '{"success": false, "error": "User not found"}'
            exit 0
        fi
        
        # Validate password length
        if [ ${#NEW_PASSWORD} -lt 6 ]; then
            json_response '{"success": false, "error": "Password must be at least 6 characters"}'
            exit 0
        fi
        
        # Hash new password
        NEW_HASH=$(hash_password "$NEW_PASSWORD")
        
        # Get current role for target user
        TARGET_ROLE=$(get_user_role "$TARGET_USER")
        
        # Update users file
        grep -v "^$TARGET_USER:" "$USERS_FILE" > "$USERS_FILE.tmp"
        echo "$TARGET_USER:$NEW_HASH:$TARGET_ROLE" >> "$USERS_FILE.tmp"
        mv "$USERS_FILE.tmp" "$USERS_FILE"
        chmod 600 "$USERS_FILE"
        
        json_response '{"success": true, "message": "Password changed successfully"}'
        ;;
    
    list-users)
        TOKEN=$(get_cookie)
        
        if ! validate_session "$TOKEN"; then
            json_response '{"success": false, "error": "Not authenticated"}'
            exit 0
        fi
        
        INFO=$(get_session_info "$TOKEN")
        CURRENT_ROLE=$(echo "$INFO" | tail -1)
        
        # Only admin can list users
        if [ "$CURRENT_ROLE" != "admin" ]; then
            json_response '{"success": false, "error": "Permission denied"}'
            exit 0
        fi
        
        # Build JSON array of users (exclude password hash)
        USERS_JSON="["
        FIRST=true
        while IFS=':' read -r username hash role; do
            if [ -n "$username" ]; then
                if [ "$FIRST" = true ]; then
                    FIRST=false
                else
                    USERS_JSON="$USERS_JSON,"
                fi
                USERS_JSON="$USERS_JSON{\"username\":\"$username\",\"role\":\"$role\"}"
            fi
        done < "$USERS_FILE"
        USERS_JSON="$USERS_JSON]"
        
        json_response "{\"success\": true, \"users\": $USERS_JSON}"
        ;;
    
    create-user)
        TOKEN=$(get_cookie)
        
        if ! validate_session "$TOKEN"; then
            json_response '{"success": false, "error": "Not authenticated"}'
            exit 0
        fi
        
        INFO=$(get_session_info "$TOKEN")
        CURRENT_ROLE=$(echo "$INFO" | tail -1)
        
        # Only admin can create users
        if [ "$CURRENT_ROLE" != "admin" ]; then
            json_response '{"success": false, "error": "Permission denied"}'
            exit 0
        fi
        
        NEW_USERNAME=$(get_post_param "username")
        NEW_PASSWORD=$(get_post_param "password")
        
        # Validate username (alphanumeric, 3-20 chars)
        if ! echo "$NEW_USERNAME" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]{2,19}$'; then
            json_response '{"success": false, "error": "Invalid username. Use 3-20 alphanumeric characters, starting with a letter."}'
            exit 0
        fi
        
        # Check if user already exists
        if grep -q "^$NEW_USERNAME:" "$USERS_FILE"; then
            json_response '{"success": false, "error": "User already exists"}'
            exit 0
        fi
        
        # Cannot create admin users
        if [ "$NEW_USERNAME" = "admin" ]; then
            json_response '{"success": false, "error": "Cannot create admin user"}'
            exit 0
        fi
        
        # Validate password length
        if [ ${#NEW_PASSWORD} -lt 6 ]; then
            json_response '{"success": false, "error": "Password must be at least 6 characters"}'
            exit 0
        fi
        
        # Hash password and add user (always as operator role)
        NEW_HASH=$(hash_password "$NEW_PASSWORD")
        echo "$NEW_USERNAME:$NEW_HASH:operator" >> "$USERS_FILE"
        chmod 600 "$USERS_FILE"
        
        json_response "{\"success\": true, \"message\": \"User '$NEW_USERNAME' created successfully\"}"
        ;;
    
    delete-user)
        TOKEN=$(get_cookie)
        
        if ! validate_session "$TOKEN"; then
            json_response '{"success": false, "error": "Not authenticated"}'
            exit 0
        fi
        
        INFO=$(get_session_info "$TOKEN")
        CURRENT_USER=$(echo "$INFO" | head -1)
        CURRENT_ROLE=$(echo "$INFO" | tail -1)
        
        # Only admin can delete users
        if [ "$CURRENT_ROLE" != "admin" ]; then
            json_response '{"success": false, "error": "Permission denied"}'
            exit 0
        fi
        
        TARGET_USER=$(get_post_param "username")
        
        # Cannot delete admin user
        if [ "$TARGET_USER" = "admin" ]; then
            json_response '{"success": false, "error": "Cannot delete admin user"}'
            exit 0
        fi
        
        # Cannot delete yourself
        if [ "$TARGET_USER" = "$CURRENT_USER" ]; then
            json_response '{"success": false, "error": "Cannot delete yourself"}'
            exit 0
        fi
        
        # Check if user exists
        if ! grep -q "^$TARGET_USER:" "$USERS_FILE"; then
            json_response '{"success": false, "error": "User not found"}'
            exit 0
        fi
        
        # Delete user from file
        grep -v "^$TARGET_USER:" "$USERS_FILE" > "$USERS_FILE.tmp"
        mv "$USERS_FILE.tmp" "$USERS_FILE"
        chmod 600 "$USERS_FILE"
        
        # Remove any active sessions for this user
        for session_file in "$SESSIONS_DIR"/*; do
            if [ -f "$session_file" ]; then
                SESSION_USER=$(sed -n '2p' "$session_file" 2>/dev/null)
                if [ "$SESSION_USER" = "$TARGET_USER" ]; then
                    rm -f "$session_file"
                fi
            fi
        done
        
        json_response "{\"success\": true, \"message\": \"User '$TARGET_USER' deleted successfully\"}"
        ;;
        
    *)
        json_response '{"error": "Unknown action"}'
        ;;
esac
