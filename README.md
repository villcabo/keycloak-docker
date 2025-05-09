# Keycloak

Keycloak is an open-source Identity and Access Management solution aimed at modern applications and services. This project provides a Dockerized setup for running Keycloak with a PostgreSQL database.

## Environment Variables

The following environment variables are required for the setup:

```properties
POSTGRES_URL=jdbc:postgresql://host:5432/keycloak
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
KEYCLOAK_USER=admin
KEYCLOAK_PASSWORD=admin
```

## Prerequisites

- Docker installed on your system.
- Docker Compose (used to manage the containers).

## Setup Instructions

1. Clone the repository:
   ```bash
   git clone https://github.com/your-repo/keycloak-docker.git
   cd keycloak-docker
   ```

2. Configure the environment variables:
   - Update the `.env` file or set the variables directly in your shell.

3. Build and start the containers using Docker Compose:
   ```bash
   docker compose up -d
   ```

4. Access Keycloak:
   - Open your browser and navigate to `http://localhost:8080`.

## Usage

- **Admin Console**: Use the admin console to configure realms, clients, and users.
- **Database**: PostgreSQL is used as the backend database for Keycloak. Ensure the credentials match your setup.

## Stopping the Containers

To stop the running containers:
```bash
docker compose down
```

## Troubleshooting

- Check container logs:
  ```bash
  docker logs <container_name>
  ```
- Verify environment variables are correctly set.

## License

This project is licensed under the MIT License.
