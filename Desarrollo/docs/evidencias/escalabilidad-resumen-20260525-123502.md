# Resumen de prueba de escalabilidad

- Fecha de ejecucion: 2026-05-25 12:35:26
- Niveles de concurrencia: 500
- Peticiones por nivel y servicio: 500
- Timeout por peticion: 20 segundos
- Evidencia detallada: docs\evidencias\escalabilidad-detalle-20260525-123502.csv
- Evidencia resumida: docs\evidencias\escalabilidad-resumen-20260525-123502.csv

| Servicio | Concurrencia | Peticiones | Exitosas | Exito | Promedio ms | P95 ms | Max ms | Throughput req/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| content-service | 500 | 500 | 500 | 100% | 839.43 | 1408.03 | 1422.79 | 290.07 |
| simulation-service | 500 | 500 | 99 | 19.8% | 576.41 | 672.94 | 683.95 | 24.77 |
| recommendation-service | 500 | 500 | 500 | 100% | 1375.63 | 1811.3 | 1838.05 | 248.21 |
