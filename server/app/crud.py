# server/app/crud.py
from datetime import datetime
from sqlalchemy.orm import Session
from sqlalchemy import func

from . import models, schemas

# ---------- APPS ----------
def create_app(db: Session, name: str, package: str | None = None, source: str | None = None, installer_path: str | None = None):
    a = models.App(name=name, package=package, source=source, installer_path=installer_path)
    db.add(a)
    db.commit()
    db.refresh(a)
    return a

def list_apps(db: Session):
    return db.query(models.App).order_by(models.App.id).all()

def get_app(db: Session, app_id: int):
    return db.query(models.App).filter(models.App.id == app_id).first()

def update_app(db: Session, app_id: int, name: str, package: str | None = None, installer_path: str | None = None):
    obj = db.query(models.App).filter(models.App.id == app_id).first()
    if not obj:
        return None
    obj.name = name
    obj.package = package
    obj.installer_path = installer_path
    db.add(obj)
    db.commit()
    db.refresh(obj)
    return obj

def delete_app(db: Session, app_id: int):
    obj = db.query(models.App).filter(models.App.id == app_id).first()
    if not obj:
        return False
    db.delete(obj)
    db.commit()
    return True

# ---------- JOB QUEUE (simple) ----------
def create_job(db: Session, app_id: int):
    job = models.Job(app_id=app_id, status="queued", created_at=datetime.utcnow())
    db.add(job)
    db.commit()
    db.refresh(job)
    return job

def list_jobs(db: Session):
    return db.query(models.Job).order_by(models.Job.id.desc()).all()

# ---------- AGENTS ----------
def list_agents(db: Session):
    return db.query(models.Agent).order_by(models.Agent.id).all()

def _get_agent_hostname_attr():
    """
    Helper to pick the attribute name that looks like hostname in models.Agent.
    Returns (attr_name, column_attr) or (None, None).
    """
    candidates = ["hostname", "device", "host", "name"]
    for c in candidates:
        if hasattr(models.Agent, c):
            return c, getattr(models.Agent, c)
    return None, None

def find_agent_by_hostname(db: Session, hostname: str):
    """
    Try to find an agent by hostname using whichever attribute exists in models.Agent.
    """
    attr_name, column = _get_agent_hostname_attr()
    if column is not None:
        return db.query(models.Agent).filter(column == hostname).first()
    # fallback: try to match against ip or token columns if present
    if hasattr(models.Agent, "ip"):
        return db.query(models.Agent).filter(models.Agent.ip == hostname).first()
    return None

def register_agent(db: Session, hostname: str, ip: str | None = None, token: str | None = None):
    """
    Create or update an agent. Returns the Agent model instance.
    main.py expects this function for /api/agents/register
    """
    # Try to find existing agent by hostname (flexible)
    existing = find_agent_by_hostname(db, hostname)
    if existing:
        # update fields if available
        updated = False
        if ip and hasattr(existing, "ip") and existing.ip != ip:
            existing.ip = ip
            updated = True
        # update last_seen if the column exists
        if hasattr(existing, "last_seen"):
            try:
                existing.last_seen = datetime.utcnow()
                updated = True
            except Exception:
                pass
        if token and hasattr(existing, "token"):
            existing.token = token
            updated = True
        if updated:
            db.add(existing)
            db.commit()
            db.refresh(existing)
        return existing

    # Create new
    kwargs = {}
    # map likely fields
    if hasattr(models.Agent, "hostname"):
        kwargs["hostname"] = hostname
    elif hasattr(models.Agent, "device"):
        kwargs["device"] = hostname
    elif hasattr(models.Agent, "host"):
        kwargs["host"] = hostname
    else:
        # if model doesn't have any of those, try a generic 'name' field
        if hasattr(models.Agent, "name"):
            kwargs["name"] = hostname

    if ip and hasattr(models.Agent, "ip"):
        kwargs["ip"] = ip
    if token and hasattr(models.Agent, "token"):
        kwargs["token"] = token
    if hasattr(models.Agent, "last_seen"):
        kwargs["last_seen"] = datetime.utcnow()

    agent = models.Agent(**kwargs)
    db.add(agent)
    db.commit()
    db.refresh(agent)
    return agent

def delete_agent(db: Session, agent_id: int):
    obj = db.query(models.Agent).filter(models.Agent.id == agent_id).first()
    if not obj:
        return False
    db.delete(obj)
    db.commit()
    return True

# ---------- LOGS ----------
def list_logs(db: Session):
    return db.query(models.InstallLog).order_by(models.InstallLog.id.desc()).all()

def create_log(db: Session, payload):
    # payload may be an InstallLogIn pydantic model or dict
    data = payload.dict() if hasattr(payload, "dict") else payload
    try:
        log = models.InstallLog(**data)
        db.add(log)
        db.commit()
        db.refresh(log)
        return log
    except Exception as e:
        # best-effort fallback to minimal fields
        try:
            log = models.InstallLog(message=str(data))
            db.add(log)
            db.commit()
            db.refresh(log)
            return log
        except Exception:
            return None
