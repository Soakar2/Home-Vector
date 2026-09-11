#pragma once

#include <cstdlib>
#include <stdexcept>
#include <string>

// Centralizes access to process environment variables so that no
// secret (DB host/user/password) is ever hardcoded or committed to
// source control. Configuration is read once at startup; if anything
// required is missing, the process fails fast with a clear message
// instead of limping along with a bad or empty connection string.
namespace telemetry::config {

inline std::string getEnvOrThrow(const char* name) {
    const char* value = std::getenv(name);
    if (value == nullptr || std::string(value).empty()) {
        throw std::runtime_error(std::string("Missing required environment variable: ") + name);
    }
    return std::string(value);
}

inline std::string getEnvOrDefault(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    if (value == nullptr || std::string(value).empty()) {
        return fallback;
    }
    return std::string(value);
}

struct DatabaseConfig {
    std::string host;
    std::string port;
    std::string dbName;
    std::string user;
    std::string password;
    std::string sslMode;
    std::size_t poolSize;

    // Builds a libpqxx-compatible keyword/value connection string.
    // This value contains the password -- callers must never log it,
    // print it, or include it in an exception message.
    std::string toConnectionString() const {
        return "host=" + host +
               " port=" + port +
               " dbname=" + dbName +
               " user=" + user +
               " password=" + password +
               " sslmode=" + sslMode;
    }

    static DatabaseConfig fromEnvironment() {
        DatabaseConfig cfg;
        cfg.host     = getEnvOrThrow("DB_HOST");
        cfg.port     = getEnvOrDefault("DB_PORT", "5432");
        cfg.dbName   = getEnvOrThrow("DB_NAME");
        cfg.user     = getEnvOrThrow("DB_USER");
        cfg.password = getEnvOrThrow("DB_PASSWORD");
        cfg.sslMode  = getEnvOrDefault("DB_SSLMODE", "prefer");

        const std::string poolSizeStr = getEnvOrDefault("DB_POOL_SIZE", "5");
        try {
            const int parsed = std::stoi(poolSizeStr);
            if (parsed <= 0) {
                throw std::invalid_argument("DB_POOL_SIZE must be positive");
            }
            cfg.poolSize = static_cast<std::size_t>(parsed);
        } catch (const std::exception&) {
            throw std::runtime_error("DB_POOL_SIZE must be a positive integer, got: " + poolSizeStr);
        }

        return cfg;
    }
};

struct AppConfig {
    int port;

    static AppConfig fromEnvironment() {
        AppConfig cfg;
        try {
            cfg.port = std::stoi(getEnvOrDefault("APP_PORT", "8080"));
        } catch (const std::exception&) {
            throw std::runtime_error("APP_PORT must be a valid integer");
        }
        return cfg;
    }
};

} // namespace telemetry::config
