from pydantic import BaseModel
from typing import Optional, Any

class AppBase(BaseModel):
    name: str
    package: Optional[str] = None
    source: Optional[str] = "choco"
    installer_path: Optional[str] = None

class AppCreate(AppBase):
    pass

class AppOut(BaseModel):
    id: int
    name: str
    package: Optional[str] = None
    source: Optional[str] = None
    installer_path: Optional[str] = None

    class Config:
        from_attributes = True  # Updated for Pydantic v2

class AgentOut(BaseModel):
    id: int
    agent_id: str
    name: Optional[str] = None
    last_seen: Optional[str] = None

    class Config:
        from_attributes = True

class JobOut(BaseModel):
    id: int
    agent_id: str
    app_id: int
    status: str
    created_at: Optional[str] = None

    class Config:
        from_attributes = True

class InstallLogIn(BaseModel):
    agent_id: str
    app_name: str
    status: str
    message: Optional[str] = None
    device_info: Optional[Any] = None