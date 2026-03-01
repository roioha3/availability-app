import uuid
from fastapi import Header, HTTPException, Depends
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.models.user import User


def get_current_user(
    db: Session = Depends(get_db),
    x_user_id: str | None = Header(default=None, alias="X-User-Id"),
) -> User:
    if not x_user_id:
        raise HTTPException(status_code=401, detail="Missing X-User-Id header")

    try:
        user_id = uuid.UUID(x_user_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="X-User-Id must be a UUID")

    user = db.get(User, user_id)
    if user is None:
        user = User(id=user_id, display_name="New User")
        db.add(user)
        db.commit()
        db.refresh(user)

    return user