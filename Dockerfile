# Use PHP 8.2 Apache base image
FROM php:8.2-apache

# Install system dependencies and PHP extensions required by PipraPay
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libonig-dev \
    libmagickwand-dev \
    libssl-dev \
    unzip
RUN docker-php-ext-configure gd --with-freetype --with-jpeg
RUN docker-php-ext-install -j$(nproc) \
        curl \
        pdo \
        pdo_mysql \
        gd \
        fileinfo
RUN docker-php-ext-install -j$(nproc) \
        zip \
        mbstring
RUN docker-php-ext-install -j$(nproc) \
        bcmath \
        opcache
RUN pecl install imagick \
    && docker-php-ext-enable imagick \
    && rm -rf /var/lib/apt/lists/*

# Enable Apache mod_rewrite for URL rewriting
RUN a2enmod rewrite

# Configure Apache MPM for prefork (required for imagick compatibility)
RUN a2dismod mpm_event && \
    a2dismod mpm_worker && \
    a2enmod mpm_prefork

# Set PHP configuration for bcscale (required by PipraPay)
RUN echo "bcmath.scale=8" >> /usr/local/etc/php/conf.d/bcmath.ini

# Set PHP upload limits and other recommended settings
RUN { \
    echo "upload_max_filesize=64M"; \
    echo "post_max_size=64M"; \
    echo "max_execution_time=300"; \
    echo "memory_limit=256M"; \
    echo "date.timezone=UTC"; \
} > /usr/local/etc/php/conf.d/piprapay.ini

# Update Apache document root and allow .htaccess overrides
RUN sed -i 's!/var/www/html!/var/www/html!g' /etc/apache2/sites-available/000-default.conf \
    && sed -i 's!/var/www/!/var/www/html!g' /etc/apache2/apache2.conf \
    && { \
    echo '<Directory /var/www/html>'; \
    echo '    Options -Indexes +FollowSymLinks'; \
    echo '    AllowOverride All'; \
    echo '    Require all granted'; \
    echo '</Directory>'; \
    } >> /etc/apache2/conf-available/piprapay.conf \
    && a2enconf piprapay

# Set Apache ServerName and DirectoryIndex
RUN echo "ServerName 0.0.0.0" >> /etc/apache2/apache2.conf && \
    echo "DirectoryIndex index.php index.html" >> /etc/apache2/apache2.conf

# Create pp-media directory and set permissions for uploads
RUN mkdir -p /var/www/html/pp-media \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && chmod -R 775 /var/www/html/pp-media

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Copy application files
COPY . /var/www/html/

# Ensure proper ownership
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && chmod -R 775 /var/www/html/pp-media

# Expose port 80 (will be mapped to 8080 via docker-compose)
EXPOSE 80

# Set entrypoint
ENTRYPOINT ["docker-entrypoint.sh"]
