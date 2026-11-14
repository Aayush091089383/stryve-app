import os
import sys
from pathlib import Path
from dotenv import load_dotenv
import psycopg

def main():
    env_path = Path('/home/aayush/campus_sync/backend/.env')
    load_dotenv(env_path)
    db_url = os.getenv('DATABASE_URL')

    if not db_url:
        print("DATABASE_URL not found in .env")
        sys.exit(1)

    try:
        with psycopg.connect(db_url, connect_timeout=10) as conn:
            with conn.cursor() as cur:
                cur.execute('SELECT 1;')
                result = cur.fetchone()[0]
                print(f"Keep-alive successful. Database responded with: {result}")
    except Exception as e:
        print(f"Keep-alive failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
