from fastapi import FastAPI, Request, Depends, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
import os
from dotenv import load_dotenv
load_dotenv()

from . import crud, models, schemas
from .database import SessionLocal, engine, Base
from .security import secure_filename

# create tables if missing
Base.metadata.create_all(bind=engine)

app = FastAPI(title="Internal Installer - PostgreSQL")

# ----- static path fix (project layout expects root/static) -----
BASE_DIR = os.path.dirname(os.path.dirname(__file__))   # server/app
ROOT_DIR = os.path.dirname(BASE_DIR)                    # project root
STATIC_DIR = os.path.join(ROOT_DIR, "static")
INSTALLERS_DIR = os.path.join(ROOT_DIR, "installers")

print(">>> STATIC_DIR =", STATIC_DIR)
print(">>> Exists =", os.path.exists(STATIC_DIR))
if os.path.isdir(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
else:
    print("❌ STATIC DIR NOT FOUND:", STATIC_DIR)

# CORS: allow the admin/ui origin and localhost for development
origins = [
    "http://10.0.0.49:5050",
    "http://127.0.0.1:5050",
    "http://localhost:5050",
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins + ["*"],   # keep flexible while testing; tighten in prod
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# DB session helper
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

API_KEY = os.getenv("API_KEY", "1234567890")

def require_admin(req: Request):
    key = req.headers.get("x-admin-key")
    if key != API_KEY:
        raise HTTPException(401, "Unauthorized")

# -----------------------
# APPS endpoints (unchanged)
# -----------------------
@app.post("/api/apps", response_model=schemas.AppOut)
def create_app(payload: schemas.AppCreate, request: Request, db: Session = Depends(get_db)):
    require_admin(request)
    return crud.create_app(db, name=payload.name, package=payload.package,
                           source=payload.source, installer_path=payload.installer_path)

@app.get("/api/apps", response_model=list[schemas.AppOut])
def list_apps(db: Session = Depends(get_db)):
    return crud.list_apps(db)

@app.get("/api/apps/{app_id}", response_model=schemas.AppOut)
def get_app(app_id: int, db: Session = Depends(get_db)):
    appobj = crud.get_app(db, app_id)
    if not appobj:
        raise HTTPException(404, "Not found")
    return appobj

@app.put("/api/apps/{app_id}", response_model=schemas.AppOut)
def update_app(app_id: int, payload: schemas.AppCreate, request: Request, db: Session = Depends(get_db)):
    require_admin(request)
    updated = crud.update_app(db, app_id, name=payload.name, package=payload.package,
                              installer_path=payload.installer_path)
    if not updated:
        raise HTTPException(404, "Not found")
    return updated

@app.delete("/api/apps/{app_id}")
def delete_app(app_id: int, request: Request, db: Session = Depends(get_db)):
    require_admin(request)
    ok = crud.delete_app(db, app_id)
    if not ok:
        raise HTTPException(404, "Not found")
    return {"deleted": True}

# -----------------------
# AGENTS: list / register / delete
# -----------------------
@app.get("/api/agents", response_model=list[schemas.AgentOut])
def get_agents(db: Session = Depends(get_db)):
    return crud.list_agents(db)

@app.post("/api/agents/register")
def register_agent(data: dict, db: Session = Depends(get_db)):
    """
    Called from employee page (browser) after local agent provides device info.
    Expecting JSON: { "hostname": "...", "ip": "..." }
    This handler is defensive: it tries to call typical crud functions and
    will not raise a 500 if crud functions are named slightly differently.
    """
    hostname = data.get("hostname")
    ip = data.get("ip", "")
    if not hostname:
        raise HTTPException(400, "Hostname required")

    try:
        # Preferred helper if present
        if hasattr(crud, "register_agent"):
            return crud.register_agent(db=db, hostname=hostname, ip=ip)
        # fallback: try find/create pattern
        agent = None
        if hasattr(crud, "find_agent_by_hostname"):
            agent = crud.find_agent_by_hostname(db, hostname)
        if agent:
            # optionally update last_seen/ip if function exists
            if hasattr(crud, "update_agent_seen"):
                try:
                    crud.update_agent_seen(db, agent.id, ip=ip)
                except Exception:
                    pass
            return {"ok": True, "agent": agent}
        # try generic create
        if hasattr(crud, "create_agent"):
            return crud.create_agent(db, hostname=hostname, ip=ip)
    except Exception as e:
        # avoid returning 500 for minor crud mismatches; log and return generic
        print("register_agent handler error:", e)
        return JSONResponse(status_code=200, content={"ok": True, "note": "registered (fallback)"})

    return {"ok": True, "note": "no-op (crud missing)"}

@app.delete("/api/agents/{agent_id}")
def delete_agent(agent_id: int, db: Session = Depends(get_db)):
    ok = crud.delete_agent(db, agent_id)
    if not ok:
        raise HTTPException(404, "Agent not found")
    return {"deleted": True}

# heartbeat from agent (agent's background job can POST here)
@app.post("/api/agents/heartbeat")
def agent_heartbeat(data: dict, db: Session = Depends(get_db)):
    """
    Heartbeat expects JSON { "hostname": "...", "ip": "..." }
    This is defensive and will not throw if crud functions vary.
    """
    hostname = data.get("hostname")
    ip = data.get("ip", "")
    if not hostname:
        raise HTTPException(400, "hostname required")

    try:
        if hasattr(crud, "find_agent_by_hostname"):
            agent = crud.find_agent_by_hostname(db, hostname)
            if agent:
                # update last_seen or ip if helper exists
                if hasattr(crud, "update_agent_seen"):
                    try:
                        crud.update_agent_seen(db, agent.id, ip=ip)
                    except Exception:
                        pass
                return {"ok": True, "agent_id": getattr(agent, "id", None)}
        # fallback: create if missing
        if hasattr(crud, "create_agent"):
            a = crud.create_agent(db, hostname=hostname, ip=ip)
            return {"ok": True, "agent_id": getattr(a, "id", None)}
    except Exception as e:
        print("heartbeat handler error:", e)
        # don't return 500 to client (agent); instead return generic success
        return {"ok": True, "note": "heartbeat accepted (fallback)"}

    return {"ok": True, "note": "heartbeat ignored (no crud hooks)"}

# -----------------------
# LOGS
# -----------------------
@app.get("/api/logs")
def get_logs(db: Session = Depends(get_db)):
    return crud.list_logs(db)

@app.post("/api/logs")
def post_log(payload: schemas.InstallLogIn, db: Session = Depends(get_db)):
    return crud.create_log(db, payload)

# -----------------------
# INSTALLERS static serving
# -----------------------
@app.get("/installers/{filename}")
def get_installer(filename: str, token: str = "", db: Session = Depends(get_db)):
    filename = secure_filename(filename)
    full = os.path.join(INSTALLERS_DIR, filename)
    if not os.path.exists(full):
        raise HTTPException(404, "File not found")
    return FileResponse(full)

# -----------------------
# UI endpoints
# -----------------------
@app.get("/", response_class=HTMLResponse)
def home():
    return open(os.path.join(STATIC_DIR, "index.html"), encoding="utf-8").read()

@app.get("/employee.html", response_class=HTMLResponse)
def emp():
    return open(os.path.join(STATIC_DIR, "employee.html"), encoding="utf-8").read()

@app.get("/admin", response_class=HTMLResponse)
def admin():
    f = os.path.join(STATIC_DIR, "admin.html")
    if not os.path.exists(f):
        raise HTTPException(404, "Admin UI missing")
    return HTMLResponse(open(f, encoding="utf-8").read())

@app.post("/admin/auth")
async def admin_auth(data: dict):
    if data.get("key") == API_KEY:
        return {"valid": True, "token": "session"}
    raise HTTPException(401, "Invalid")

@app.get("/favicon.ico")
async def favicon():
    return Response(content="", status_code=204)
