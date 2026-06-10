from typing import Optional
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from ...libs.media_api.types import (
    MediaSearchResult,
    MediaType,
    UserMediaListStatus,
    UserMediaListSort,
    UserProfile,
)
from ...libs.media_api.params import UserMediaListSearchParams
from pydantic import BaseModel
import logging
from threading import Lock
import time

from ..deps import get_ctx, get_media_api

logger = logging.getLogger(__name__)

router = APIRouter()

# Track media IDs that were deleted locally but whose AniList sync hasn't
# completed yet. These are filtered from list responses so the UI doesn't
# show items that the user just deleted (before AniList confirms).
_pending_deletions: set[int] = set()

# Serialized AniList sync queue per media ID
_sync_lock = Lock()
_active_syncs: set[int] = set()
_pending_updates: dict[int, tuple[Optional[UserMediaListStatus], Optional[int], Optional[float]]] = {}


class ListUpdateRequest(BaseModel):
    media_id: int
    status: Optional[UserMediaListStatus] = None
    progress: Optional[int] = None
    score: Optional[float] = None


def _queue_sync_update(
    media_id: int,
    status: Optional[UserMediaListStatus],
    progress: Optional[int],
    score: Optional[float],
    background_tasks: BackgroundTasks,
) -> None:
    """Queue AniList updates for media_id sequentially."""
    with _sync_lock:
        ctx = get_ctx()

        # Default to passed parameters
        latest_status = status
        latest_progress = progress
        latest_score = score

        # If registry supports get_media_index_entry, get fully merged values
        if hasattr(ctx.media_registry, "get_media_index_entry"):
            local_entry = ctx.media_registry.get_media_index_entry(media_id)
            if local_entry:
                latest_status = local_entry.status
                latest_progress = int(local_entry.progress) if local_entry.progress.isdigit() else 0
                latest_score = local_entry.score

        # Merge with existing queued update if one is already in queue
        if media_id in _pending_updates:
            prev_status, prev_progress, prev_score = _pending_updates[media_id]
            if latest_status is None:
                latest_status = prev_status
            if latest_progress is None:
                latest_progress = prev_progress
            if latest_score is None:
                latest_score = prev_score

        _pending_updates[media_id] = (latest_status, latest_progress, latest_score)

        if media_id not in _active_syncs:
            _active_syncs.add(media_id)
            background_tasks.add_task(_run_sync_worker, media_id)


def _run_sync_worker(media_id: int) -> None:
    """Worker task that processes queued updates for a specific media_id sequentially."""
    while True:
        with _sync_lock:
            if media_id not in _pending_updates:
                _active_syncs.discard(media_id)
                break
            status, progress, score = _pending_updates.pop(media_id)

        try:
            from ...libs.media_api.params import UpdateUserMediaListEntryParams  # noqa: PLC0415

            ctx = get_ctx()
            params = UpdateUserMediaListEntryParams(
                media_id=media_id,
                status=status,
                progress=str(progress) if progress is not None else None,
                score=score,
            )
            logger.info(
                f"Syncing state to AniList in background for media {media_id}: status={status}, progress={progress}, score={score}"
            )
            ctx.media_api.update_list_entry(params)
        except Exception as e:
            logger.error(f"Failed to sync state to AniList in background: {e}")

        # Introduce a 500ms delay to throttle requests and avoid rate limit issues
        time.sleep(0.5)


def _sync_delete(media_id: int) -> None:
    """Background task: sync a list deletion with AniList."""
    try:
        ctx = get_ctx()
        if ctx.media_api.delete_list_entry(media_id):
            # Success: AniList confirmed deletion, safe to clear from pending set.
            _pending_deletions.discard(media_id)
        # If AniList returns False (entry not found / timed out), keep the
        # ID in _pending_deletions so list queries continue filtering it.
    except Exception:
        # Network error: keep filtering until the next successful sync.
        pass


@router.get("/profile", response_model=Optional[UserProfile])
def get_profile(api=Depends(get_media_api)):
    """Get the authenticated user's profile."""
    try:
        if not api.is_authenticated():
            return None
        return api.get_viewer_profile()
    except Exception:
        return None


@router.get("/list", response_model=MediaSearchResult)
def get_user_list(
    api=Depends(get_media_api),
    status: Optional[UserMediaListStatus] = None,
    type: Optional[MediaType] = None,
    page: int = 1,
):
    """Get the authenticated user's media list."""
    try:
        if not api.is_authenticated():
            from ...libs.media_api.types import PageInfo

            return MediaSearchResult(
                page_info=PageInfo(
                    total=0, current_page=1, has_next_page=False, per_page=15
                ),
                media=[],
            )

        params = UserMediaListSearchParams(
            status=status or UserMediaListStatus.WATCHING,
            type=type,
            page=page,
            sort=UserMediaListSort.UPDATED_TIME_DESC,
        )
        result = api.search_media_list(params)
        if not result:
            from ...libs.media_api.types import PageInfo

            return MediaSearchResult(
                page_info=PageInfo(
                    total=0, current_page=1, has_next_page=False, per_page=15
                ),
                media=[],
            )

        ctx = get_ctx()
        resolved_status = status or UserMediaListStatus.WATCHING

        # Filter and merge list results
        filtered_media = []
        result_media_ids = set()

        if result.media:
            for media in result.media:
                # Filter out pending deletions
                if _pending_deletions and media.id in _pending_deletions:
                    continue

                local_entry = ctx.media_registry.get_media_index_entry(media.id)
                if local_entry:
                    # Filter out if status doesn't match the requested status
                    if local_entry.status != resolved_status:
                        continue

                    # Merge status/progress/score
                    if not media.user_status:
                        from ...libs.media_api.types import UserListItem  # noqa: PLC0415
                        media.user_status = UserListItem(
                            status=local_entry.status,
                            progress=int(local_entry.progress) if local_entry.progress.isdigit() else 0,
                            score=local_entry.score,
                        )
                    else:
                        if local_entry.progress.isdigit():
                            media.user_status.progress = int(local_entry.progress)
                        if local_entry.status:
                            media.user_status.status = local_entry.status
                        if local_entry.score is not None:
                            media.user_status.score = local_entry.score

                filtered_media.append(media)
                result_media_ids.add(media.id)

        # Inject items that are locally in this status but not in the AniList response yet.
        # Only inject if there is a pending AniList sync (i.e. the user just modified it
        # locally). Stale entries from items the user completed on AniList directly are
        # skipped, preventing the local watching list from showing stale "watching" items.
        index = ctx.media_registry._load_index()
        for key, entry in index.media_index.items():
            if _pending_deletions and entry.media_id in _pending_deletions:
                continue

            if (
                entry.status == resolved_status
                and entry.media_id not in result_media_ids
                and entry.media_id in _pending_updates
            ):
                record = ctx.media_registry.get_media_record(entry.media_id)
                if record and record.media_item:
                    media = record.media_item
                    # Filter by type if requested
                    if type:
                        # Normalize type comparison
                        media_type_val = media.type.value if hasattr(media.type, "value") else str(media.type)
                        req_type_val = type.value if hasattr(type, "value") else str(type)
                        if media_type_val != req_type_val:
                            continue

                    # Merge local status
                    if not media.user_status:
                        from ...libs.media_api.types import UserListItem  # noqa: PLC0415
                        media.user_status = UserListItem(
                            status=entry.status,
                            progress=int(entry.progress) if entry.progress.isdigit() else 0,
                            score=entry.score,
                        )
                    else:
                        if entry.progress.isdigit():
                            media.user_status.progress = int(entry.progress)
                        if entry.status:
                            media.user_status.status = entry.status
                        if entry.score is not None:
                            media.user_status.score = entry.score

                    filtered_media.insert(0, media)  # Prepend for instant feedback!
                    result_media_ids.add(media.id)

        result.media = filtered_media
        if result.page_info:
            result.page_info.total = len(filtered_media)

        return result
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/update")
async def update_list_entry(req: ListUpdateRequest, background_tasks: BackgroundTasks):
    """Update a user's list entry for a media item."""
    try:
        ctx = get_ctx()
        progress_str = str(req.progress) if req.progress is not None else None

        # 1. Update local registry immediately (instant, no network)
        ctx.media_registry.update_media_index_entry(
            media_id=req.media_id,
            status=req.status,
            progress=progress_str,
            score=req.score,
        )

        # 2. Bump data version so UI refetches
        ctx.data_version += 1

        # 3. Fire AniList sync in the background (does not block response)
        _queue_sync_update(req.media_id, req.status, req.progress, req.score, background_tasks)

        # 4. Clear playback state
        from .status import clear_playback  # noqa: PLC0415

        clear_playback(background_tasks)

        return {"status": "success", "synced": "pending"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{media_id}")
async def delete_list_entry(media_id: int, background_tasks: BackgroundTasks):
    """Delete a user's list entry for a media item."""
    try:
        ctx = get_ctx()

        # 1. Remove from local registry immediately (instant, no network)
        ctx.media_registry.remove_media_record(media_id)

        # 2. Track pending deletion so list queries filter it out until AniList syncs
        _pending_deletions.add(media_id)

        # 3. Bump data version so UI refetches
        ctx.data_version += 1

        # 4. Fire AniList deletion in the background (does not block response)
        background_tasks.add_task(_sync_delete, media_id)

        # 5. Clear playback state
        from .status import clear_playback  # noqa: PLC0415

        clear_playback(background_tasks)

        return {"status": "success", "deleted": "pending"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
