from server.app.database import SessionLocal, engine
from server.app import models
from server.app.crud import create_app
# create tables
models.Base.metadata.create_all(bind=engine)
db = SessionLocal()
defaults = [
    ("Visual Studio Code", "vscode"),
    ("Git", "git"),
    ("NodeJS", "nodejs"),
    ("Notepad++", "notepadplusplus"),
    ("Google Chrome", "googlechrome")
]
for name, pkg in defaults:
    existing = db.query(models.App).filter(models.App.name==name).first()
    if not existing:
        create_app(db, name=name, package=pkg, source="choco")
print("Seed complete")
db.close()