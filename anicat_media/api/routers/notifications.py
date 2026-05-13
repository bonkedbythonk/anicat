from typing import List
from fastapi import APIRouter, HTTPException
from ...libs.media_api.types import Notification

router = APIRouter()

def get_ctx():
    from ..main import ctx
    return ctx

@router.get("/", response_model=List[Notification])
async def get_notifications():
    """Get the authenticated user's unread notifications."""
    try:
        ctx = get_ctx()
        if not ctx.media_api.is_authenticated():
            raise HTTPException(status_code=401, detail="Not authenticated")
        
        notifications = ctx.media_api.get_notifications()
        return notifications or []
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
