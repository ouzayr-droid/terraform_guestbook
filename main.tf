provider "aws" {
  region = "us-east-2"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
}

resource "aws_subnet" "secondary" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
}

resource "aws_subnet" "tertiary" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# route table pour les subnets publics
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

# route table pour les subnets privés
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

# association des subnets publics à la route table publique
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.public.id
}

# association des subnets privés à la route table privée
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.secondary.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private2" {
  subnet_id      = aws_subnet.tertiary.id
  route_table_id = aws_route_table.private.id
}

# -------------------------------------Security Group--------------------------------------
resource "aws_security_group" "main" {
  name        = "web-sg"
  description = "Security group pour web servers"
  vpc_id      = "rien ici pour l'instant"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2-rds-1" {
  name        = "ec2-rds-sg"
  description = "Security group pour EC2 et RDS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.main.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg_ext" {
  name        = "db-sg-ext"
  description = "Security group pour RDS accessible depuis l'extérieur"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds-ec2-1" {
  name        = "rds-ec2-sg"
  description = "Security group pour RDS accessible depuis EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.ec2-rds-1.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "db_host" {
  value = aws_rds_instance.db.endpoint
}

# -------------------------------------DB subnet group--------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "main"
  subnet_ids = [aws_subnet.secondary.id, aws_subnet.tertiary.id]
}

# -------------------------------------Instance RDS--------------------------------------
resource "aws_db_instance" "db" {
  identifier         = "mydbinstance11032026"
  db_name            = "db"
  allocated_storage  = 10
  engine             = "mariadb"
  engine_version     = "11.8"
  instance_class     = "db.t4g.micro"
  username           = "admin"
  password           = "password1234"
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds-ec2-1.id, aws_security_group.db_sg_ext.id]

  tags = {
    Name = "MyDBInstance"
  }
}

# -------------------------------------Instance EC2--------------------------------------
resource "aws_instance" "web" {
  ami           = "ami-06e3c045d79fd65d9" # Ubuntu server 24.04 LTS
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.main.id
  security_groups = [aws_security_group.main.name]

  user_data =   <<-EOF
                #!/usr/bin/env bash
                set -euo pipefail

                APP_DIR="/home/ubuntu/app"
                SERVICE_NAME="flaskapp"
                DB_HOST="${aws_db_instance.db.endpoint}"
                DB_NAME="${aws_db_instance.db.name}"
                DB_USER="admin"
                DB_PASSWORD="password1234"
                APP_PORT="80"

                export DEBIAN_FRONTEND=noninteractive

                sudo apt update
                sudo apt install -y python3 python3-pip python3-venv mysql-client
                sudo setcap 'cap_net_bind_service=+ep' $(readlink -f $(which python3))
                sudo mkdir -p "$APP_DIR"
                sudo chown -R ubuntu:ubuntu "$APP_DIR"

                cat > "$APP_DIR/data.sql" <<EOF2
                CREATE DATABASE IF NOT EXISTS ${DB_NAME};

                USE ${DB_NAME};

                CREATE TABLE IF NOT EXISTS messages (
                id INT AUTO_INCREMENT PRIMARY KEY,
                message VARCHAR(255) NOT NULL
                );

                INSERT INTO messages (message)
                SELECT 'Bonjour depuis AWS'
                WHERE NOT EXISTS (
                SELECT 1 FROM messages WHERE message = 'Bonjour depuis AWS'
                );
                EOF2
                echo "Attente MySQL..."
                until mysqladmin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" --silent; do
                sleep 5
                done

                echo "Import SQL..."
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" < "$APP_DIR/data.sql"

                cat > "$APP_DIR/app.py" <<PYEOF
                from flask import Flask, request, redirect
                import mysql.connector
                import os

                app = Flask(__name__)

                def get_db_connection():
                    return mysql.connector.connect(
                        host=os.environ.get("DB_HOST", "127.0.0.1"),
                        user=os.environ.get("DB_USER", "appuser"),
                        password=os.environ.get("DB_PASSWORD", "password"),
                        database=os.environ.get("DB_NAME", "guestbook")
                    )

                @app.route("/")
                def index():
                    db = get_db_connection()
                    cursor = db.cursor()
                    cursor.execute("SELECT message FROM messages ORDER BY id DESC")
                    results = cursor.fetchall()
                    cursor.close()
                    db.close()

                    html = """
                    <h1>AWS Guestbook</h1>
                    <form method=\"POST\" action=\"/add\">
                        <input type=\"text\" name=\"message\" placeholder=\"Votre message\" required>
                        <button type=\"submit\">Envoyer</button>
                    </form>
                    <ul>
                    """

                    for row in results:
                        html += f"<li>{row[0]}</li>"

                    html += "</ul>"
                    return html

                @app.route("/add", methods=["POST"])
                def add():
                    message = request.form["message"]
                    db = get_db_connection()
                    cursor = db.cursor()
                    cursor.execute("INSERT INTO messages (message) VALUES (%s)", (message,))
                    db.commit()
                    cursor.close()
                    db.close()
                    return redirect("/")

                if __name__ == "__main__":
                    app.run(host="0.0.0.0", port=int(os.environ.get("APP_PORT", "3000")))
                PYEOF

                python3 -m venv "$APP_DIR/venv"
                source "$APP_DIR/venv/bin/activate"
                pip install --upgrade pip
                pip install flask mysql-connector-python python-dotenv

                deactivate

                cat > "$APP_DIR/.env" <<ENVEOF
                DB_HOST=${DB_HOST}
                DB_NAME=${DB_NAME}
                DB_USER=${DB_USER}
                DB_PASSWORD=${DB_PASSWORD}
                APP_PORT=${APP_PORT}
                ENVEOF

                sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<SERVICEEOF
                [Unit]
                Description=Application Flask Guestbook
                After=network.target

                [Service]
                User=ubuntu
                WorkingDirectory=${APP_DIR}
                EnvironmentFile=${APP_DIR}/.env
                ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/app.py
                Restart=always

                [Install]
                WantedBy=multi-user.target
                SERVICEEOF

                sudo systemctl daemon-reload
                sudo systemctl enable ${SERVICE_NAME}
                sudo systemctl restart ${SERVICE_NAME}
                sudo systemctl status ${SERVICE_NAME} --no-pager || true

                echo "Installation Flask terminée. Application disponible sur le port ${APP_PORT}."
                EOF

  tags = {
    Name = "WebServer"
  }
}

output "public_ip" {
  value = aws_instance.web_server.public_ip
}

output "endpoint" {
  value = "http://${aws_instance.web.public_ip}:${APP_PORT}"    
  
}