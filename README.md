# Plataforma Adaptativa de Aprendizaje — Guía de ejecución

Stack: Jakarta EE 10 · WildFly 35 · JSF 4.0 · PrimeFaces 14 · PostgreSQL 16 · Docker

## Requisitos previos

- Java 21
- Maven 3.9+
- Docker y Docker Compose

Verificar:

```bash
java -version
mvn -version
docker --version
docker compose version
```

---

## 1. Compilar todos los módulos

Desde la carpeta `Desarrollo/`:

```bash
mvn clean package -DskipTests
```

Esto genera los `.war` de los cinco módulos:
- `content-service/target/content-service.war`
- `user-service/target/user-service.war`
- `simulation-service/target/simulation-service.war`
- `recommendation-service/target/recommendation-service.war`
- `Presentacion/target/presentacion.war`

---

## 2. Levantar todos los contenedores

```bash
docker compose up --build -d
```

Docker levanta en orden:
1. Bases de datos (`content_db`, `user_db`, `recommendation_db`)
2. Servicios backend (`content-service`, `user-service`, `simulation-service`, `recommendation-service`)
3. Frontend (`presentacion`)

Esperar hasta que todos estén `healthy` (puede tardar 2-3 minutos la primera vez):

```bash
docker compose ps
```

---

## 3. Verificar que los servicios responden

```bash
curl http://localhost:8081/api/courses          # content-service
curl http://localhost:8082/api/enrollments/1   # user-service
curl http://localhost:8083/api/recommendations/user/1  # recommendation-service
```

---

## 4. Abrir la aplicación

```
http://localhost:8085
```

---

## 5. Primer uso: generar recomendaciones iniciales

Después del primer arranque, ejecutar el análisis para el usuario 1 (enrollment 1):

```bash
curl -s -X POST http://localhost:8083/api/analysis/enrollments/1 \
     -H "Content-Type: application/json" > /dev/null && echo "Análisis completado"
```

Esto crea las recomendaciones iniciales basadas en el progreso existente.

---

## Puertos expuestos

| Contenedor             | Puerto HTTP | Consola admin |
|------------------------|-------------|---------------|
| `presentacion`         | 8085        | 9995          |
| `simulation-service`   | 8080        | 9990          |
| `content-service`      | 8081        | 9991          |
| `user-service`         | 8082        | 9992          |
| `recommendation-service` | 8083      | 9993          |
| `content_db` (PostgreSQL) | 5432     | —             |
| `user_db` (PostgreSQL)    | 5433     | —             |
| `recommendation_db` (PostgreSQL) | 5434 | —          |

---

## Comandos útiles

### Ver logs de un servicio
```bash
docker logs presentacion -f
docker logs content-service -f
docker logs recommendation-service -f
```

### Conectarse a una base de datos
```bash
# content_db
docker exec -it content_db psql -U content_user -d content_db

# user_db
docker exec -it user_db psql -U user_user -d user_db

# recommendation_db
docker exec -it recommendation_db psql -U rec_user -d recommendation_db
```

### Recompilar y redesplegar un módulo sin reconstruir la imagen Docker

```bash
# Ejemplo: redesplegar la presentación
mvn -pl Presentacion package -DskipTests
docker cp Presentacion/target/presentacion.war \
         presentacion:/opt/jboss/wildfly/standalone/deployments/

# Ejemplo: redesplegar el recommendation-service
mvn -pl recommendation-service package -DskipTests
docker cp recommendation-service/target/recommendation-service.war \
         recommendation-service:/opt/jboss/wildfly/standalone/deployments/
```

### Detener todos los contenedores
```bash
docker compose down
```

### Detener y borrar también los datos (bases de datos)
```bash
docker compose down -v
```

> Después de `down -v` es necesario volver a ejecutar los pasos 1 y 2 completos, y repetir el paso 5.
