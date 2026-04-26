use actix_web::{web, HttpResponse};

use crate::AppState;

pub async fn metrics(state: web::Data<AppState>) -> HttpResponse {
    let db = state.db.lock().unwrap();

    let user_count: i64 = db
        .query_row("SELECT COUNT(*) FROM users", [], |row| row.get(0))
        .unwrap_or(0);
    let tx_count: i64 = db
        .query_row("SELECT COUNT(*) FROM transactions", [], |row| row.get(0))
        .unwrap_or(0);
    let msg_count: i64 = db
        .query_row("SELECT COUNT(*) FROM messages", [], |row| row.get(0))
        .unwrap_or(0);

    let mut output = String::new();
    output.push_str("# HELP bank_users_total Total registered users\n");
    output.push_str("# TYPE bank_users_total gauge\n");
    output.push_str(&format!("bank_users_total {}\n", user_count));
    output.push_str("# HELP bank_transactions_total Total transactions\n");
    output.push_str("# TYPE bank_transactions_total gauge\n");
    output.push_str(&format!("bank_transactions_total {}\n", tx_count));
    output.push_str("# HELP bank_messages_total Total messages\n");
    output.push_str("# TYPE bank_messages_total gauge\n");
    output.push_str(&format!("bank_messages_total {}\n", msg_count));

    HttpResponse::Ok()
        .content_type("text/plain; version=0.0.4")
        .body(output)
}

pub async fn health() -> HttpResponse {
    HttpResponse::Ok().body("ok")
}
