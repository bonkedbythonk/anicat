import os
import sys
import uvicorn

if __package__ is None and not getattr(sys, "frozen", False):
    import os.path
    path = os.path.realpath(os.path.abspath(__file__))
    sys.path.insert(0, os.path.dirname(os.path.dirname(path)))

from anicat_media.api.main import create_app

if __name__ == "__main__":
    app = create_app()
    uvicorn.run(app, host="127.0.0.1", port=13370)
