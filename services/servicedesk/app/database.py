import os
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase
from config import settings

# 1. Настройка движка и сессий
engine = create_async_engine(settings.database_url, echo=False)
AsyncSessionLocal = async_sessionmaker(
    bind=engine, 
    class_=AsyncSession, 
    expire_on_commit=False
)

# 2. Базовый класс для моделей
class Base(DeclarativeBase):
    pass

# 3. Зависимость для FastAPI
async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()

# 4. Функция инициализации (которой не хватало)
async def init_db():
    # Импортируем модели внутри, чтобы они зарегистрировались в Base.metadata
    import models.user
    import models.ticket
    import models.artifact
    import models.report
    import models.share_token
    import models.ticket_message
    import models.integration
    import models.ticket_event

    async with engine.begin() as conn:
        # Создаем таблицы, если их нет
        await conn.run_sync(Base.metadata.create_all)
    
    # Создаем последовательности (sequences), если они используются в utils/refs.py
    async with AsyncSessionLocal() as session:
        await session.execute(text("CREATE SEQUENCE IF NOT EXISTS ticket_case_seq START 1"))
        await session.execute(text("CREATE SEQUENCE IF NOT EXISTS artifact_ref_seq START 1"))
        await session.commit()

    # Запускаем сидинг аккаунта поддержки
    await _seed_support_account()

# 5. Логика сидинга (ваша существующая логика)
async def _seed_support_account():
    from models.user import User, UserRole
    from utils.auth import hash_password
    
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            text("SELECT id FROM users WHERE username = :username"),
            {"username": settings.support_username},
        )
        existing_user_id = result.scalar_one_or_none()
        
        password = settings.support_password
        if not password:
            raise ValueError("SUPPORT_PASSWORD must be set!")
        
        if existing_user_id:
            # Обновление существующего
            res = await session.execute(
                select(User).where(User.id == existing_user_id)
            )
            user = res.scalar_one()
            user.hashed_password = hash_password(password)
            user.role = UserRole.agent
            user.workspace = "operations"
            user.queue_scope = "all"
            user.access_level = 5
            await session.commit()
            print(f"Support account {settings.support_username} updated", flush=True)
            return
        
        # Создание нового
        support_user = User(
            username=settings.support_username,
            email=settings.support_email,
            hashed_password=hash_password(password),
            role=UserRole.agent,
            access_level=5,
            workspace="operations",
            queue_scope="all",
        )
        session.add(support_user)
        await session.commit()
        
        if not os.getenv("PRODUCTION"):
            print(f"DEV ONLY - Support account: {settings.support_username} / {password}", flush=True)
        else:
            print(f"Support account {settings.support_username} seeded", flush=True)

# Вспомогательный импорт для сидинга
from sqlalchemy import select
