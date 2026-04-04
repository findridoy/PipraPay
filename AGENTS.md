# PipraPay Agent Guidelines

PipraPay is a self-hosted PHP payment automation platform with a plugin-based architecture.

## Project Structure

```
PipraPay/
├── index.php              # Main entry point, router
├── pp-config.php          # Database configuration (if installed)
├── .htaccess             # URL rewriting rules
├── pp-content/
│   ├── pp-include/
│   │   ├── pp-functions.php   # Core functions
│   │   └── pp-adapter.php     # System adapter, requirements check
│   ├── pp-admin/         # Admin panel files
│   ├── pp-modules/
│   │   ├── pp-gateways/  # Payment gateway plugins
│   │   ├── pp-addons/    # Addon plugins
│   │   └── pp-themes/    # Theme plugins
│   └── pp-install/       # Installation wizard
├── assets/               # Static assets (CSS, JS, images)
└── pp-media/             # User-uploaded files
```

## Build/Development Commands

Since this is a pure PHP project without Node.js tooling:

- **No build step required** - PHP files are interpreted directly
- **No package manager** - No composer.json at root level
- **No automated tests** - No PHPUnit configured
- **No linting** - Follow code style guidelines below manually

For gateway modules with composer dependencies (e.g., `nagad-merchant-api`):
```bash
cd pp-content/pp-modules/pp-gateways/<gateway-name>/
composer install
```

## Code Style Guidelines

### PHP Basics
- Use `declare(strict_types=1);` at the start of every PHP file
- PHP 8.1.x - 8.3.x compatibility required
- 4 spaces for indentation (no tabs)
- Always use UTF-8 encoding

### File Structure
```php
<?php
    declare(strict_types=1);

    if (!defined('PipraPay_INIT')) {
        http_response_code(403);
        exit('Direct access not allowed');
    }

    // Code here
```

### Naming Conventions
- **Classes**: PascalCase (e.g., `StripeGateway`, `MyCustomGateway`)
- **Functions**: snake_case with `pp_` prefix for core functions (e.g., `pp_site_url()`, `pp_callback_url()`)
- **Variables**: snake_case (e.g., `$gateway_id`, `$customer_info`)
- **Constants**: UPPER_CASE with `PipraPay_` prefix (e.g., `PipraPay_INIT`)
- **Database tables**: Lowercase with underscores, use `$db_prefix`

### Gateway Plugin Structure
Each gateway must be in `pp-content/pp-modules/pp-gateways/{slug}/`:
```
stripe/
├── class.php          # Main gateway class (required)
└── assets/
    └── logo.jpg       # Gateway logo (optional)
```

Gateway class naming: Convert slug to PascalCase + "Gateway"
- `stripe` → `StripeGateway`
- `bkash-merchant` → `BkashMerchantGateway`

### Required Gateway Methods
```php
class StripeGateway
{
    public function info(): array
    {
        return [
            'title'       => 'Stripe Gateway',
            'logo'        => 'assets/logo.jpg',
            'currency'    => 'USD',
            'tab'         => 'global',
            'gateway_type'=> 'api',
        ];
    }

    public function fields(): array
    {
        return [
            [
                'name'  => 'secret_key',
                'label' => 'Stripe Secret Key',
                'type'  => 'text',
            ],
        ];
    }

    public function process_payment(array $data = []): void
    {
        // Process payment logic
    }

    public function callback(array $data = []): void
    {
        // Handle callback/webhook
    }

    public function ipn(array $data = []): void
    {
        // Handle Instant Payment Notification
    }
}
```

### Database Operations
Use the built-in helper functions:
```php
// Fetch data
$params = [':gateway_id' => $gateway_id];
$response = json_decode(getData($db_prefix.'gateways', 'WHERE gateway_id = :gateway_id', '* FROM', $params), true);

// Insert data
$columns = ['brand_id', 'ref', 'amount'];
$values = [$brand_id, $ref, $amount];
insertData($db_prefix.'transaction', $columns, $values);

// Update data
updateData($db_prefix.'transaction', ['status' => 'completed'], 'WHERE ref = :ref', [':ref' => $ref]);
```

### Error Handling
- Use try-catch for database operations
- Return JSON errors for API endpoints with proper HTTP status codes
- Log errors appropriately

```php
http_response_code(400);
echo json_encode([
    'error' => [
        'code'    => 'INVALID_GATEWAY',
        'message' => 'The Gateway provided is incorrect or invalid.'
    ]
]);
exit;
```

### Security Requirements
1. **Always check `PipraPay_INIT`** at the start of included files
2. **Use prepared statements** - Never concatenate SQL directly
3. **Validate all inputs** - Use `filter_var()`, `preg_match()` for validation
4. **Escape output** - Use appropriate escaping for HTML/JSON
5. **CSRF tokens** - Include in all forms
6. **Security headers** - Already set in index.php (X-Frame-Options, X-Content-Type-Options)

### Money/Financial Operations
Always use the money helper functions:
```php
$rounded = money_round($amount);           // Round to configured precision
$sanitized = money_sanitize($amount);      // Sanitize input
$sum = money_add($a, $b);                  // Safe addition
$difference = money_sub($a, $b);           // Safe subtraction
```

### API Development
- Use `getAuthorizationHeader()` for API key extraction
- Validate scopes before processing
- Return proper JSON responses

### Common Global Variables Available
- `$db_prefix` - Database table prefix
- `$site_url` - Base site URL
- `$path_admin` - Admin path
- `$csrf_token` - Current CSRF token
- `$global_user_login` - User login status
- `$global_response_brand` - Current brand info

## License & Branding
- Licensed under **AGPL-3.0**
- Keep all PipraPay branding intact
- Do not rebrand as another product
- All contributions must be compatible with AGPL-3.0

## Resources
- Documentation: https://piprapay.readme.io/
- Developer Guides: Check `docs/` folder (if present)
- Demo: https://demo.piprapay.com/admin/login (demo / 12345678)
