#pragma once

#include <pqxx/pqxx>

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <stdexcept>
#include <string>

// A small, fixed-size, thread-safe pool of libpqxx connections.
//
// Crow serves requests from a pool of worker threads. A pqxx::connection
// is NOT safe to share across threads, so every in-flight request must
// borrow its own connection and give it back when it's done. `acquire()`
// returns an RAII guard (ConnectionGuard) that automatically returns the
// connection to the pool when it goes out of scope -- even if an
// exception is thrown while handling the request -- so a failed request
// can never leak a connection.
namespace telemetry::db {

class ConnectionPool {
public:
    ConnectionPool(const std::string& connectionString, std::size_t size) {
        if (size == 0) {
            throw std::invalid_argument("Connection pool size must be greater than zero");
        }
        for (std::size_t i = 0; i < size; ++i) {
            available_.push(std::make_shared<pqxx::connection>(connectionString));
        }
    }

    // Non-copyable, non-movable: owns live DB connections and is meant
    // to be constructed once at startup and shared by reference/pointer.
    ConnectionPool(const ConnectionPool&) = delete;
    ConnectionPool& operator=(const ConnectionPool&) = delete;

    class ConnectionGuard {
    public:
        ConnectionGuard(ConnectionPool& pool, std::shared_ptr<pqxx::connection> conn)
            : pool_(&pool), conn_(std::move(conn)) {}

        ~ConnectionGuard() {
            if (conn_ && pool_) {
                pool_->release(conn_);
            }
        }

        ConnectionGuard(const ConnectionGuard&) = delete;
        ConnectionGuard& operator=(const ConnectionGuard&) = delete;

        ConnectionGuard(ConnectionGuard&& other) noexcept
            : pool_(other.pool_), conn_(std::move(other.conn_)) {
            other.pool_ = nullptr;
        }

        pqxx::connection& get() { return *conn_; }

    private:
        ConnectionPool* pool_;
        std::shared_ptr<pqxx::connection> conn_;
    };

    // Blocks up to `timeoutMs` for a free connection. Throws
    // std::runtime_error on timeout so callers can turn that into a
    // 503/500 response instead of hanging the request indefinitely.
    ConnectionGuard acquire(int timeoutMs = 3000) {
        std::unique_lock<std::mutex> lock(mutex_);
        const bool gotOne = cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                                          [this] { return !available_.empty(); });
        if (!gotOne) {
            throw std::runtime_error("Timed out waiting for an available database connection");
        }
        auto conn = available_.front();
        available_.pop();
        return ConnectionGuard(*this, std::move(conn));
    }

private:
    void release(const std::shared_ptr<pqxx::connection>& conn) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            available_.push(conn);
        }
        cv_.notify_one();
    }

    std::mutex mutex_;
    std::condition_variable cv_;
    std::queue<std::shared_ptr<pqxx::connection>> available_;
};

} // namespace telemetry::db
