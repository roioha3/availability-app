from datetime import datetime, timedelta, timezone

from fastapi import FastAPI, Depends
from sqlalchemy.orm import Session
from fastapi.middleware.cors import CORSMiddleware
from app.core.db import get_db
from app.core.auth import get_current_user
from app.models.user import User
from app.models.presence import Presence
import uuid
from pydantic import BaseModel
from app.models.friend import FriendEdge

app = FastAPI(title="Availability App API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # later restrict to your app domains
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
TTL_SECONDS = 120  # availability expires unless refreshed


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/presence/available")
def set_available(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    now = datetime.now(timezone.utc)
    until = now + timedelta(seconds=TTL_SECONDS)

    presence = db.get(Presence, user.id)
    if presence is None:
        presence = Presence(user_id=user.id, available_until=until)
        db.add(presence)
    else:
        presence.available_until = until

    db.commit()
    return {"user_id": str(user.id), "available_until": until.isoformat()}


@app.post("/presence/unavailable")
def set_unavailable(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    presence = db.get(Presence, user.id)
    if presence is None:
        presence = Presence(user_id=user.id, available_until=None)
        db.add(presence)
    else:
        presence.available_until = None

    db.commit()
    return {"user_id": str(user.id), "available_until": None}


@app.post("/presence/heartbeat")
def heartbeat(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    now = datetime.now(timezone.utc)
    until = now + timedelta(seconds=TTL_SECONDS)

    presence = db.get(Presence, user.id)
    if presence is None:
        # If user never set available, heartbeat does nothing
        presence = Presence(user_id=user.id, available_until=None)
        db.add(presence)
        db.commit()
        return {"user_id": str(user.id), "available_until": None, "note": "not available"}

    # Only extend if currently available and not expired
    if presence.available_until and presence.available_until > now:
        presence.available_until = until
        db.commit()
        return {"user_id": str(user.id), "available_until": until.isoformat()}

    return {"user_id": str(user.id), "available_until": None, "note": "expired/not available"}

class ContactSyncRequest(BaseModel):
    friend_user_ids: list[uuid.UUID]


@app.post("/contacts/sync")
def contacts_sync(
    payload: ContactSyncRequest,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    # Remove self if included
    friend_ids = [fid for fid in payload.friend_user_ids if fid != user.id]

    # Delete existing edges for this user (simple "replace" semantics)
    db.query(FriendEdge).filter(FriendEdge.user_id == user.id).delete()

    # Insert new edges
    for fid in friend_ids:
        db.add(FriendEdge(user_id=user.id, friend_user_id=fid))

    db.commit()

    return {"user_id": str(user.id), "friends_count": len(friend_ids)}

@app.get("/friends/available")
def get_available_friends(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    now = datetime.now(timezone.utc)

    # Get friend ids for this user
    friend_ids = (
        db.query(FriendEdge.friend_user_id)
        .filter(FriendEdge.user_id == user.id)
        .all()
    )
    friend_ids = [row[0] for row in friend_ids]

    if not friend_ids:
        return {"available": []}

    presences = (
        db.query(Presence)
        .filter(
            Presence.available_until.isnot(None),
            Presence.available_until > now,
            Presence.user_id.in_(friend_ids),
        )
        .all()
    )

    return {
        "available": [
            {
                "user_id": str(p.user_id),
                "available_until": p.available_until.isoformat(),
            }
            for p in presences
        ]
    }
    
@app.get("/me")
def me(user: User = Depends(get_current_user)):
    return {"user_id": str(user.id), "display_name": user.display_name}