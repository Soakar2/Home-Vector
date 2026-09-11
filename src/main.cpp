#include "crow.h"
#include <nlohmann/json.hpp>
#include <pqxx/pqxx>

#include "Config.hpp"
#include "ConnectionPool.hpp"
#include "TelemetryPayload.hpp"

#include <cstdlib>
#include <iostream>
#include <memory>

using json = nlohmann::json;
using namespace telemetry;

namespace {

crow::response makeJsonResponse(int status, const json& body) {
    crow::response res(status, body.dump());
    res.set_header("Content-Type", "application/json");
    return res;
}

// Persists a single validated telemetry reading.
//
// Uses pqxx::params exclusively -- every value is sent as a bound
// parameter, never concatenated into the SQL string -- so this call is
// not vulnerable to SQL injection no matter what a device sends as
// device_id or timestamp.
bool insertTelemetry(db::ConnectionPool& pool, const model::TelemetryPayload& payload, std::string& error) {
    try {
        auto guard = pool.acquire();
        pqxx::work txn(guard.get());

        const pqxx::params insertParams{
            payload.deviceId,
            payload.timestamp,
            payload.temperature,
            payload.location.lat,
            payload.location.lon};

        txn.exec(
            "INSERT INTO telemetry_readings "
            "(device_id, recorded_at, temperature, latitude, longitude) "
            "VALUES ($1, $2::timestamptz, $3, $4, $5)",
            insertParams);

        txn.commit();
        return true;
    } catch (const std::exception& ex) {
        error = ex.what();
        return false;
    }
}

} // namespace

int main() {
    // Fail fast if the environment isn't configured -- never fall back
    // to hardcoded or default database credentials.
    config::DatabaseConfig dbConfig;
    config::AppConfig appConfig;
    try {
        dbConfig = config::DatabaseConfig::fromEnvironment();
        appConfig = config::AppConfig::fromEnvironment();
    } catch (const std::exception& ex) {
        std::cerr << "Configuration error: " << ex.what() << std::endl;
        return EXIT_FAILURE;
    }

    std::unique_ptr<db::ConnectionPool> pool;
    try {
        pool = std::make_unique<db::ConnectionPool>(dbConfig.toConnectionString(), dbConfig.poolSize);
        std::cout << "Connected to PostgreSQL at " << dbConfig.host << ":" << dbConfig.port
                  << "/" << dbConfig.dbName << " (pool size " << dbConfig.poolSize << ")" << std::endl;
    } catch (const std::exception& ex) {
        // libpqxx connection-failure messages can include the
        // host/user (though never the password) -- printing them is
        // fine for a startup log but is intentionally kept generic
        // here so nothing about the DB topology leaks into stdout/stderr
        // by default. Enable verbose startup logging deliberately if needed.
        std::cerr << "Failed to initialize database connection pool. "
                  << "Check DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD and that PostgreSQL is reachable."
                  << std::endl;
        return EXIT_FAILURE;
    }

    crow::SimpleApp app;

    CROW_ROUTE(app, "/healthz")
    .methods(crow::HTTPMethod::GET)
    ([]() {
        return makeJsonResponse(200, {{"status", "ok"}});
    });

    CROW_ROUTE(app, "/api/v1/telemetry")
    .methods(crow::HTTPMethod::POST)
    ([&pool](const crow::request& req) {
        json body;
        try {
            body = json::parse(req.body);
        } catch (const json::parse_error&) {
            return makeJsonResponse(400, {{"error", "Malformed JSON body"}});
        }

        std::string validationError;
        const auto payload = model::parseTelemetryPayload(body, validationError);
        if (!payload.has_value()) {
            return makeJsonResponse(400, {{"error", validationError}});
        }

        std::string dbError;
        if (!insertTelemetry(*pool, *payload, dbError)) {
            std::cerr << "Database error while inserting telemetry: " << dbError << std::endl;
            return makeJsonResponse(500, {{"error", "Failed to persist telemetry reading"}});
        }

        return makeJsonResponse(201, {
            {"status", "accepted"},
            {"device_id", payload->deviceId}
        });
    });

    app.port(appConfig.port).multithreaded().run();

    return 0;
}
