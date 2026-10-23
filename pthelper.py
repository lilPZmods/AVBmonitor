"""Pro Tools helper for the AVB manager's recovery (talks to Pro Tools' scripting interface, PTSL).

    pthelper.py info   -> {"running": true, "path": "/…/Session.ptx", "name": "Session"}
    pthelper.py save   -> {"ok": true}

Installed with its own Python environment by install.sh.
"""
import json
import sys


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "info"
    try:
        from ptsl import open_engine
        with open_engine(company_name="Arraymusic", application_name="AVBWatch") as e:
            if cmd == "info":
                print(json.dumps({"running": True, "path": e.session_path(), "name": e.session_name()}))
            elif cmd == "save":
                e.save_session()
                print(json.dumps({"ok": True}))
            else:
                print(json.dumps({"error": f"unknown command {cmd}"}))
                sys.exit(2)
    except Exception as ex:  # Pro Tools closed, no session open, or scripting refused
        print(json.dumps({"running": False, "error": f"{type(ex).__name__}: {ex}"[:300]}))
        sys.exit(1)


if __name__ == "__main__":
    main()
