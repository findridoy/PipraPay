#!/bin/bash
set -e

# Configuration from environment variables
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-piprapay}"
DB_USER="${DB_USER:-piprapay}"
DB_PASS="${DB_PASS:-}"
DB_PREFIX="${DB_PREFIX:-pp_}"

ADMIN_NAME="${ADMIN_NAME:-Administrator}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

CONFIG_FILE="/var/www/html/pp-config.php"
MARKER_FILE="/var/www/html/.setup-complete"
INSTALL_DIR="/var/www/html/pp-content/pp-install"

# Generate a secure password if not provided
generate_password() {
    tr -dc 'A-Za-z0-9@#$%&!' < /dev/urandom | head -c 12
}

# Wait for MySQL to be ready
wait_for_mysql() {
    echo "[PipraPay Setup] Waiting for MySQL at ${DB_HOST}:${DB_PORT}..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if php -r "
            try {
                \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
                echo 'OK';
            } catch (Exception \$e) {
                echo 'FAIL';
            }
        " 2>/dev/null | grep -q "OK" || true; then
            echo "[PipraPay Setup] MySQL is ready!"
            return 0
        fi
        
        echo "[PipraPay Setup] Attempt $attempt/$max_attempts - MySQL not ready yet, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "[PipraPay Setup] ERROR: Could not connect to MySQL after $max_attempts attempts"
    return 1
}

# Check database connection and exit on failure
check_connection() {
    echo "[PipraPay Setup] Verifying database connection..."
    
    local connection_test=$(php -r "
        try {
            \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
            echo 'SUCCESS';
        } catch (Exception \$e) {
            echo 'ERROR: ' . \$e->getMessage();
        }
    " 2>/dev/null)
    
    if echo "$connection_test" | grep -qx "SUCCESS" || true; then
        echo "[PipraPay Setup] Database connection verified successfully"
        return 0
    else
        echo "[PipraPay Setup] ERROR: Database connection failed"
        echo "[PipraPay Setup] Details: $connection_test"
        exit 1
    fi
}

# Create or update pp-config.php
create_config() {
    local config_updated=false
    local existing_host=""
    local existing_port=""
    local existing_user=""
    local existing_pass=""
    local existing_db_name=""
    local existing_db_prefix=""
    
    # Read existing config values if file exists
    if [ -f "$CONFIG_FILE" ]; then
        echo "[PipraPay Setup] Reading existing pp-config.php..."
        
        # Extract values from existing config using PHP
        local config_values=$(php -r "
            include '${CONFIG_FILE}';
            echo (\$db_host ?? 'NULL') . '|';
            echo (\$db_user ?? 'NULL') . '|';
            echo (\$db_pass ?? 'NULL') . '|';
            echo (\$db_name ?? 'NULL') . '|';
            echo (\$db_prefix ?? 'NULL') . '|';
        " 2>/dev/null)
        
        # Extract port from host if present
        if echo "$existing_host" | grep -q ":"; then
            existing_port=$(echo "$existing_host" | cut -d':' -f2)
            existing_host=$(echo "$existing_host" | cut -d':' -f1)
        else
            existing_port="3306"
        fi
        
        # Check if connection parameters changed
        if [ "$existing_host" != "$DB_HOST" ] || \
           [ "$existing_port" != "$DB_PORT" ] || \
           [ "$existing_user" != "$DB_USER" ] || \
           [ "$existing_pass" != "$DB_PASS" ]; then
            echo "[PipraPay Setup] Database connection settings changed, updating pp-config.php..."
            config_updated=true
            
            # Only preserve table prefix, use new database name from env vars
            if [ -n "$existing_db_prefix" ] && [ "$existing_db_prefix" != "NULL" ]; then
                DB_PREFIX="$existing_db_prefix"
                echo "[PipraPay Setup] Preserving table prefix: ${DB_PREFIX}"
            fi
        else
            echo "[PipraPay Setup] Database connection settings unchanged"
        fi
    else
        echo "[PipraPay Setup] Creating new pp-config.php..."
        config_updated=true
    fi
    
    # Write config file
    # Include port in host if non-standard
    local host_with_port="${DB_HOST}"
    if [ "${DB_PORT}" != "3306" ]; then
        host_with_port="${DB_HOST}:${DB_PORT}"
    fi
    
    cat > "$CONFIG_FILE" << EOF
<?php
    \$db_host = '${host_with_port}';
    \$db_user = '${DB_USER}';
    \$db_pass = '${DB_PASS}';
    \$db_name = '${DB_NAME}';
    \$db_prefix = '${DB_PREFIX}';
?>
EOF
    
    chown www-data:www-data "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    
    if [ "$config_updated" = true ]; then
        echo "[PipraPay Setup] pp-config.php updated successfully"
    else
        echo "[PipraPay Setup] pp-config.php is up to date"
    fi
}

# Import database schema if needed
import_database() {
    echo "[PipraPay Setup] Checking database schema..."
    
    local table_check=$(php -r "
        try {
            \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
            \$stmt = \$pdo->query(\"SHOW TABLES LIKE '${DB_PREFIX}admin'\");
            echo \$stmt->rowCount() > 0 ? 'EXISTS' : 'NOT_EXISTS';
        } catch (Exception \$e) {
            echo 'ERROR: ' . \$e->getMessage();
        }
    " 2>/dev/null)
    
    # Check if tables already exist
    if echo "$table_check" | grep -qx "EXISTS"; then
        echo "[PipraPay Setup] Database tables already exist, skipping import"
        return 0
    fi
    
    # Check for errors in table check
    if echo "$table_check" | grep -q "ERROR"; then
        echo "[PipraPay Setup] ERROR checking database tables: $table_check"
        return 1
    fi
    
    echo "[PipraPay Setup] Database appears empty, importing schema..."
    
    if [ ! -f "${INSTALL_DIR}/db.sql" ]; then
        echo "[PipraPay Setup] ERROR: db.sql not found at ${INSTALL_DIR}/db.sql"
        return 1
    fi
    
    # Execute SQL import
    local import_output=$(php -r "
        try {
            \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
            \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
            
            \$sql = file_get_contents('${INSTALL_DIR}/db.sql');
            if ('${DB_PREFIX}' !== 'pp_') {
                \$sql = str_replace('pp_', '${DB_PREFIX}', \$sql);
            }
            
            \$pdo->exec(\$sql);
            echo 'IMPORT_SUCCESS';
        } catch (Exception \$e) {
            echo 'IMPORT_ERROR: ' . \$e->getMessage();
        }
    " 2>/dev/null)
    
    if echo "$import_output" | grep -qx "IMPORT_SUCCESS"; then
        echo "[PipraPay Setup] Database schema imported successfully"
        return 0
    else
        echo "[PipraPay Setup] ERROR: Failed to import database schema"
        echo "[PipraPay Setup] Details: $import_output"
        return 1
    fi
}

# Generate IDs and password
generate_item_id() {
    local length="${1:-10}"
    tr -dc '0-9' < /dev/urandom | head -c "$length"
}

# Create admin account
create_admin() {
    echo "[PipraPay Setup] Checking admin account..."
    
    local admin_check=$(php -r "
        try {
            \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
            \$stmt = \$pdo->query(\"SELECT a_id FROM ${DB_PREFIX}admin WHERE username = '${ADMIN_USERNAME}' LIMIT 1\");
            \$result = \$stmt->fetch(PDO::FETCH_ASSOC);
            echo \$result ? \$result['a_id'] : 'NOT_EXISTS';
        } catch (Exception \$e) {
            echo 'ERROR';
        }
    " 2>/dev/null)
    
    # Use exact match to prevent false positives
    if echo "$admin_check" | grep -qx "NOT_EXISTS"; then
        echo "[PipraPay Setup] No existing admin with username '${ADMIN_USERNAME}', will create new account"
        
    elif echo "$admin_check" | grep -q "ERROR"; then
        echo "[PipraPay Setup] ERROR checking admin account: $admin_check"
        return 1
        
    else
        local existing_a_id="$admin_check"
        echo "[PipraPay Setup] Admin account '${ADMIN_USERNAME}' already exists with a_id: ${existing_a_id}"
        
        # Check if permission exists for this admin
        local permission_exists=$(php -r "
            try {
                \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
                \$stmt = \$pdo->query(\"SELECT brand_id FROM ${DB_PREFIX}permission WHERE a_id = '${existing_a_id}' LIMIT 1\");
                \$result = \$stmt->fetch(PDO::FETCH_ASSOC);
                echo \$result ? \$result['brand_id'] : 'NOT_EXISTS';
            } catch (Exception \$e) {
                echo 'ERROR';
            }
        " 2>/dev/null)
        
        if echo "$permission_exists" | grep -q "ERROR"; then
            echo "[PipraPay Setup] ERROR checking permission: $permission_exists"
            return 1
        fi
        
        if ! echo "$permission_exists" | grep -qx "NOT_EXISTS"; then
            local existing_brand_id="$permission_exists"
            echo "[PipraPay Setup] Permission record exists with brand_id: ${existing_brand_id}"
            
            # Check if brand record exists
            local brand_exists=$(php -r "
                try {
                    \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
                    \$stmt = \$pdo->query(\"SELECT COUNT(*) FROM ${DB_PREFIX}brands WHERE brand_id = '${existing_brand_id}'\");
                    echo \$stmt->fetchColumn() > 0 ? 'EXISTS' : 'NOT_EXISTS';
                } catch (Exception \$e) {
                    echo 'ERROR';
                }
            " 2>/dev/null)
            
            if echo "$brand_exists" | grep -qx "EXISTS"; then
                echo "[PipraPay Setup] Brand record exists, all setup complete"
                return 0
            else
                echo "[PipraPay Setup] Brand record missing for brand_id: ${existing_brand_id}, creating brand..."
                # Create brand and currency only
                create_brand_only "$existing_brand_id" "$(date '+%Y-%m-%d %H:%M:%S')"
                return 0
            fi
        fi
        
        echo "[PipraPay Setup] Permission record missing, will create permission and brand for existing admin"
        # Use existing a_id and create permission/brand only
        local a_id="$existing_a_id"
        local brand_id=$(generate_item_id 15)
        local current_date=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Create permission and brand only (admin already exists)
        create_permission_and_brand "$a_id" "$brand_id" "$current_date"
        return 0
    fi
    
    # Generate password if not provided
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(generate_password)
        echo "[PipraPay Setup] ==================================="
        echo "[PipraPay Setup] AUTO-GENERATED ADMIN PASSWORD: ${ADMIN_PASSWORD}"
        echo "[PipraPay Setup] ==================================="
        echo "[PipraPay Setup] IMPORTANT: Save this password now! It won't be shown again."
    fi
    
    echo "[PipraPay Setup] Creating admin account..."
    
    local a_id=$(generate_item_id 15)
    local brand_id=$(generate_item_id 15)
    local hashed_pass=$(php -r "echo password_hash('${ADMIN_PASSWORD}', PASSWORD_BCRYPT);")
    local temp_pass=$(generate_password)
    local hashed_temp_pass=$(php -r "echo password_hash('${temp_pass}', PASSWORD_BCRYPT);")
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Create admin
    php -r "
        try {
            \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
            \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
            
            // Insert admin
            \$stmt = \$pdo->prepare(\"INSERT INTO ${DB_PREFIX}admin (a_id, full_name, username, email, password, temp_password, reset_limit, status, role, 2fa_status, 2fa_secret, created_date, updated_date) VALUES (?, ?, ?, ?, ?, ?, '3', 'active', 'admin', 'disable', '--', ?, ?)\");
            \$stmt->execute(['${a_id}', '${ADMIN_NAME}', '${ADMIN_USERNAME}', '${ADMIN_EMAIL}', '${hashed_pass}', '${hashed_temp_pass}', '${current_date}', '${current_date}']);
            
            echo 'ADMIN_CREATED';
        } catch (Exception \$e) {
            echo 'ADMIN_ERROR: ' . \$e->getMessage();
        }
    " 2>/dev/null
    
    # Create permission and brand
    create_permission_and_brand "$a_id" "$brand_id" "$current_date"
    
    echo "[PipraPay Setup] Admin account created successfully"
    echo "[PipraPay Setup] Username: ${ADMIN_USERNAME}"
    echo "[PipraPay Setup] Email: ${ADMIN_EMAIL}"
}

# Create permission and brand records
create_permission_and_brand() {
    local a_id="$1"
    local brand_id="$2"
    local current_date="$3"
    
    echo "[PipraPay Setup] Creating permission and brand records..."
    
    php -r "
        try {
            \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
            \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
            
            \$permissionSchema = [
                'resources' => [
                    'customers' => ['create' => true, 'edit' => true, 'delete' => true],
                    'transaction' => ['edit' => true, 'delete' => true, 'approve' => true, 'cancel' => true, 'refund' => true, 'send_ipn' => true],
                    'invoice' => ['create' => true, 'edit' => true, 'delete' => true],
                    'payment_link' => ['create' => true, 'edit' => true, 'delete' => true],
                    'gateways' => ['create' => true, 'edit' => true, 'delete' => true],
                    'addons' => ['create' => true, 'edit' => true, 'delete' => true],
                    'brand_settings' => ['view' => true, 'edit' => true],
                    'api_settings' => ['view' => true, 'create' => true, 'edit' => true, 'delete' => true],
                    'theme_settings' => ['view' => true, 'edit' => true],
                    'faq_settings' => ['view' => true, 'create' => true, 'edit' => true, 'delete' => true],
                    'currency_settings' => ['view' => true, 'sync_rate' => true, 'import' => true, 'edit' => true],
                    'sms_data' => ['create' => true, 'edit' => true, 'delete' => true],
                    'device' => ['connect' => true, 'delete' => true, 'balance_verification_for' => true],
                    'brands' => ['create' => true, 'edit' => true, 'delete' => true],
                    'staff' => ['create' => true, 'edit' => true, 'delete' => true, 'assign_brand_to' => true, 'edit_permission' => true, 'view_permission_list' => true, 'delete_permission_of' => true],
                    'domains' => ['whitelist' => true, 'edit' => true, 'delete' => true],
                    'system_settings' => ['manage_general' => true, 'manage_cron' => true, 'manage_update' => true, 'manage_import' => true],
                ],
                'pages' => [
                    'dashboard' => true, 'customers' => true, 'transactions' => true, 'invoice' => true,
                    'payment_links' => true, 'gateways' => true, 'addons' => true, 'balance' => true,
                    'brands' => true, 'staff' => true, 'domains' => true, 'sms_data' => true,
                    'brand_settings' => true, 'my_account' => true, 'activities' => true, 'reports' => true
                ]
            ];
            
            // Insert permission (status column has DEFAULT, so we omit it)
            \$stmt = \$pdo->prepare(\"INSERT INTO ${DB_PREFIX}permission (brand_id, a_id, permission, created_date, updated_date) VALUES (?, ?, ?, ?, ?)\");
            \$stmt->execute(['${brand_id}', '${a_id}', json_encode(\$permissionSchema), '${current_date}', '${current_date}']);
            
            // Insert brand - NOTE: brands table does NOT have a_id or status columns
            \$stmt = \$pdo->prepare(\"INSERT INTO ${DB_PREFIX}brands (brand_id, name, identify_name, currency_code, language, timezone, created_date, updated_date) VALUES (?, NULL, 'Default', 'BDT', 'en', 'Asia/Dhaka', ?, ?)\");
            \$stmt->execute(['${brand_id}', '${current_date}', '${current_date}']);
            
            // Insert default currency
            \$stmt = \$pdo->prepare(\"INSERT INTO ${DB_PREFIX}currency (brand_id, code, symbol, rate, created_date, updated_date) VALUES (?, 'BDT', '৳', '1.00', ?, ?)\");
            \$stmt->execute(['${brand_id}', '${current_date}', '${current_date}']);
            
            echo 'BRAND_CREATED';
        } catch (Exception \$e) {
            echo 'BRAND_ERROR: ' . \$e->getMessage();
        }
    " 2>/dev/null
}

# Create brand and currency only (when permission exists but brand doesn't)
create_brand_only() {
    local brand_id="$1"
    local current_date="$2"
    
    echo "[PipraPay Setup] Creating brand and currency records..."
    
    php -r "
        try {
            \$pdo = new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};charset=utf8mb4', '${DB_USER}', '${DB_PASS}');
            \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
            
            // Insert brand - NOTE: brands table does NOT have a_id or status columns
            \$stmt = \$pdo->prepare(\"INSERT INTO ${DB_PREFIX}brands (brand_id, name, identify_name, currency_code, language, timezone, created_date, updated_date) VALUES (?, NULL, 'Default', 'BDT', 'en', 'Asia/Dhaka', ?, ?)\");
            \$stmt->execute(['${brand_id}', '${current_date}', '${current_date}']);
            
            // Insert default currency
            \$stmt = \$pdo->prepare(\"INSERT INTO ${DB_PREFIX}currency (brand_id, code, symbol, rate, created_date, updated_date) VALUES (?, 'BDT', '৳', '1.00', ?, ?)\");
            \$stmt->execute(['${brand_id}', '${current_date}', '${current_date}']);
            
            echo 'BRAND_CREATED';
        } catch (Exception \$e) {
            echo 'BRAND_ERROR: ' . \$e->getMessage();
        }
    " 2>/dev/null
}

# Main setup process
main() {
    echo "[PipraPay Setup] ========================================="
    echo "[PipraPay Setup] Starting PipraPay Auto-Configuration..."
    echo "[PipraPay Setup] ========================================="
    
    # Skip setup if requested
    if [ "${SKIP_AUTO_SETUP:-false}" = "true" ]; then
        echo "[PipraPay Setup] SKIP_AUTO_SETUP is true, using web installer..."
        echo "[PipraPay Setup] Access http://localhost:8080/install to complete setup"
        exec apache2-foreground
        return
    fi
    
    # Wait for MySQL (always needed for admin check)
    if ! wait_for_mysql; then
        echo "[PipraPay Setup] ERROR: Cannot proceed without database connection"
        exit 1
    fi
    
    # Check if full setup was already completed
    if [ -f "$MARKER_FILE" ] && [ "${FORCE_SETUP:-false}" != "true" ]; then
        echo "[PipraPay Setup] Setup already completed. Checking admin account..."
        # Always check/create admin on startup (in case admin was deleted)
        create_admin
        echo "[PipraPay Setup] Starting Apache..."
        exec apache2-foreground
        return
    fi
    
    # Full setup (first time or FORCE_SETUP)
    echo "[PipraPay Setup] Running full setup..."
    
    # Create or update configuration
    create_config
    
    # Verify database connection after config update
    check_connection
    
    # Import database if empty
    import_database
    
    # Create admin account
    if ! create_admin; then
        echo "[PipraPay Setup] ERROR: Admin creation failed, cannot start"
        exit 1
    fi
    touch "$MARKER_FILE"
    chown www-data:www-data "$MARKER_FILE"
    
    echo "[PipraPay Setup] ========================================="
    echo "[PipraPay Setup] Setup completed successfully!"
    echo "[PipraPay Setup] Access your panel at: http://localhost:8080/admin/login"
    echo "[PipraPay Setup] ========================================="
    
    # Start Apache
    exec apache2-foreground
}

# Run main function
main "$@"
