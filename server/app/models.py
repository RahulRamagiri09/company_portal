from sqlalchemy import Column, Integer, String, DateTime, Text, JSON, ForeignKey
from sqlalchemy.sql import func
from .database import Base

class App(Base):
    __tablename__ = "apps"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True, nullable=False)
    package = Column(String)
    source = Column(String, default="choco")
    installer_path = Column(String, nullable=True)
    silent_args = Column(String, default="")

class Agent(Base):
    __tablename__ = "agents"
    id = Column(Integer, primary_key=True, index=True)
    agent_id = Column(String, index=True)
    name = Column(String)
    last_seen = Column(DateTime, server_default=func.now())

class Job(Base):
    __tablename__ = "jobs"
    id = Column(Integer, primary_key=True, index=True)
    agent_id = Column(String, index=True)
    app_id = Column(Integer, ForeignKey("apps.id"))
    status = Column(String, default="pending")
    created_at = Column(DateTime, server_default=func.now())

class InstallLog(Base):
    __tablename__ = "install_logs"
    id = Column(Integer, primary_key=True, index=True)
    agent_id = Column(String, index=True)
    app_name = Column(String)
    status = Column(String)
    message = Column(Text)
    device_info = Column(JSON)
    timestamp = Column(DateTime, server_default=func.now())