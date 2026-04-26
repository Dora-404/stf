use actix_web::{web, HttpRequest, HttpResponse};
use chrono::Utc;
use rusqlite::params;
use uuid::Uuid;

use crate::auth;
use crate::models::{TransactionInfo, TransactionsQuery, TransferReq};
use crate::AppState;

pub async fn transfer(
    state: web::Data<AppState>,
    req: HttpRequest,
    body: web::Json<TransferReq>,
) -> HttpResponse {
    let claims = match auth::require_claims(&req, &state.keys) {
        Ok(c) => c,
        Err(resp) => return resp,
    };

    if body.amount <= 0.0 {
        return HttpResponse::BadRequest()
            .json(serde_json::json!({"error": "Amount must be positive"}));
    }
    if body.amount > 1_000_000.0 {
        return HttpResponse::BadRequest()
            .json(serde_json::json!({"error": "Amount exceeds limit"}));
    }

    let comment = body.comment.clone().unwrap_or_default();
    if comment.len() > 256 {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Comment too long"}));
    }

    let db = state.db.lock().unwrap();

    // BEGIN IMMEDIATE acquires a write lock immediately, preventing concurrent
    // transfers from racing between the balance read and the deduction.
    if db.execute_batch("BEGIN IMMEDIATE").is_err() {
        return HttpResponse::InternalServerError()
            .json(serde_json::json!({"error": "Could not start transaction"}));
    }

    let to_id = if body.to.len() == 36 && body.to.contains('-') {
        let exists = db
            .query_row("SELECT 1 FROM users WHERE id = ?1", params![body.to], |_| Ok(true))
            .unwrap_or(false);
        if !exists {
            db.execute_batch("ROLLBACK").ok();
            return HttpResponse::NotFound()
                .json(serde_json::json!({"error": "Recipient not found"}));
        }
        body.to.clone()
    } else {
        match db.query_row(
            "SELECT id FROM users WHERE username = ?1",
            params![body.to],
            |row| row.get::<_, String>(0),
        ) {
            Ok(id) => id,
            Err(_) => {
                db.execute_batch("ROLLBACK").ok();
                return HttpResponse::NotFound()
                    .json(serde_json::json!({"error": "Recipient not found"}));
            }
        }
    };

    if to_id == claims.sub {
        db.execute_batch("ROLLBACK").ok();
        return HttpResponse::BadRequest()
            .json(serde_json::json!({"error": "Cannot transfer to yourself"}));
    }

    let from_balance: f64 = match db.query_row(
        "SELECT balance FROM users WHERE id = ?1",
        params![claims.sub],
        |row| row.get(0),
    ) {
        Ok(b) => b,
        Err(_) => {
            db.execute_batch("ROLLBACK").ok();
            return HttpResponse::NotFound()
                .json(serde_json::json!({"error": "Sender not found"}));
        }
    };

    if from_balance < body.amount {
        db.execute_batch("ROLLBACK").ok();
        return HttpResponse::BadRequest().json(serde_json::json!({
            "error": "Insufficient funds",
            "balance": from_balance
        }));
    }

    let tx_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    db.execute(
        "UPDATE users SET balance = balance - ?1 WHERE id = ?2",
        params![body.amount, claims.sub],
    )
    .unwrap();
    db.execute(
        "UPDATE users SET balance = balance + ?1 WHERE id = ?2",
        params![body.amount, to_id],
    )
    .unwrap();
    db.execute(
        "INSERT INTO transactions (id, from_user, to_user, amount, comment, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![tx_id, claims.sub, to_id, body.amount, comment, now],
    )
    .unwrap();

    db.execute_batch("COMMIT").unwrap();

    HttpResponse::Ok().json(serde_json::json!({
        "id": tx_id,
        "from_user": claims.sub,
        "to_user": to_id,
        "amount": body.amount,
        "balance": from_balance - body.amount,
    }))
}

pub async fn list_transactions(
    state: web::Data<AppState>,
    req: HttpRequest,
    query: web::Query<TransactionsQuery>,
) -> HttpResponse {
    let claims = match auth::require_claims(&req, &state.keys) {
        Ok(c) => c,
        Err(resp) => return resp,
    };

    let limit = query.limit.unwrap_or(50).clamp(1, 200);

    let order = match query
        .order
        .as_deref()
        .unwrap_or("desc")
        .to_lowercase()
        .as_str()
    {
        "asc" => "ASC",
        _ => "DESC",
    };

    let order_column = match query.sort.as_deref().unwrap_or("created_at") {
        "amount" => "t.amount",
        "id" => "t.id",
        _ => "t.created_at",
    };

    let sql = format!(
        "SELECT t.id, t.from_user, t.to_user,
                fu.username, tu.username,
                t.amount, t.comment, t.created_at
         FROM transactions t
         JOIN users fu ON fu.id = t.from_user
         JOIN users tu ON tu.id = t.to_user
         WHERE t.from_user = ?1 OR t.to_user = ?1
         ORDER BY {} {}
         LIMIT ?2",
        order_column, order
    );

    let db = state.db.lock().unwrap();
    let mut stmt = match db.prepare(&sql) {
        Ok(s) => s,
        Err(_) => {
            return HttpResponse::InternalServerError()
                .json(serde_json::json!({"error": "Query error"}))
        }
    };

    let rows = stmt.query_map(params![claims.sub, limit], |row| {
        Ok(TransactionInfo {
            id: row.get(0)?,
            from_user: row.get(1)?,
            to_user: row.get(2)?,
            from_username: row.get(3)?,
            to_username: row.get(4)?,
            amount: row.get(5)?,
            comment: row.get(6)?,
            created_at: row.get(7)?,
        })
    });

    let txs: Vec<TransactionInfo> = match rows {
        Ok(r) => r.filter_map(|x| x.ok()).collect(),
        Err(_) => {
            return HttpResponse::InternalServerError()
                .json(serde_json::json!({"error": "Query failed"}))
        }
    };

    HttpResponse::Ok().json(txs)
}
