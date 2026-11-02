# AirPlay Subtitle Bridge

App personal para iPhone/iPad (iOS/iPadOS 26 o posterior) que navega un catálogo de anime a través de un bridge propio, reproduce el episodio elegido y lo envía por AirPlay con los subtítulos como pistas HLS reales. El bridge también guarda, por identidad, el progreso de **Continuar viendo** y las preferencias de catálogo y reproducción.

```text
App iOS: buscar → serie → episodio → servidor
                       │
                       ▼
Bridge: metadatos públicos del reproductor → HLS + VTT + idioma de audio
                       │
                       ▼
AVPlayer en iPhone/iPad ───────── AirPlay ─────────► TV
```

No se pega una URL HLS o VTT en la app. El bridge obtiene los metadatos de episodio y servidor con las mismas solicitudes AJAX públicas que usa la página de origen, descifra la fuente temporal y sirve un manifiesto HLS que declara cada VTT como subtítulo y el idioma del audio (japonés para Sub, inglés para Dub) para que `AVPlayer` active los subtítulos correctos. Las pistas *Forced* (sólo carteles y canciones) se marcan como forzadas y no aparecen como opción. Cada VTT recibe un `X-TIMESTAMP-MAP` anclado al primer instante real del vídeo: los reproductores de Apple ubican los subtítulos por marca de tiempo y, sin él, se desfasan tanto como tarde en arrancar el stream (más de un segundo en algunos episodios).

Las URLs y tokens temporales del proveedor no se registran en disco y desaparecen al reiniciar el bridge. Si usas identidades, la app incluye su propio token en las URLs HLS temporales que necesita el receptor AirPlay; por eso deben viajar siempre por HTTPS fuera de tu red local.

## Uso de la app

1. Instala el IPA (ver [Releases](#versiones-y-releases)).
2. En el primer uso, **Buscar**, **Recientes** y **Continuar** permanecen bloqueados y ofrecen un acceso directo a **Configuración**.
3. En **Configuración → Bridge** elige `https://` (predeterminado) o `http://` y escribe sólo el dominio o la IP, con puerto si hace falta (`bridge.midominio.com` o `192.168.1.20:8787`). Si pegas una dirección con `http://` o `https://`, el prefijo se quita del campo y el selector adopta ese protocolo. **Probar y guardar** activa la dirección únicamente si `/health` responde.
4. Si el bridge requiere identidad, créala, restáurala desde el Llavero de iCloud o importa un token (ver [Identidades](#identidades)).
5. Busca una serie (al abrir **Buscar** el campo se activa con el teclado) o entra en **Recientes**, donde cada póster muestra el episodio más reciente, el total si se conoce y los episodios en Dub. Elige episodio y servidor (`Sub` o `Dub`; el predeterminado está en Configuración).

### Reproductor

- El vídeo ocupa siempre toda la pantalla; los controles flotan encima con Liquid Glass y nunca lo redimensionan.
- Un toque muestra u oculta todos los controles a la vez; se ocultan solos tras unos segundos de reproducción.
- Incluye AirPlay, imagen dentro de imagen, ±10 s, episodio anterior/siguiente sin cerrar el reproductor, un panel de subtítulos, audio y velocidad, ajuste/relleno de pantalla (también con gesto de pellizco) y botones **Saltar intro/outro**.
- Sub activa los subtítulos automáticamente: el idioma elegido en **Subtítulos en Sub**, si no el idioma del dispositivo y, si no existe, la pista predeterminada del bridge (inglés). Cambiar de subtítulo durante un episodio Sub actualiza esa preferencia.
- Los controles de la pantalla bloqueada y del Centro de control funcionan mientras se reproduce por AirPlay.

Usa el botón AirPlay del reproductor, no **Duplicar pantalla**: la app configura la sesión de vídeo de larga duración para que el TV reciba vídeo, audio y pistas VTT.

### Continuar viendo

Guarda la serie, episodio, servidor, tipo (Sub/Dub) y segundo actual de las últimas 50 series. **Continuar** reanuda directamente con el mismo servidor y tipo. Al abrir una serie, el botón **Continuar** aparece en la temporada que tenga progreso; cambiar de temporada actualiza la misma pantalla, así que **Atrás** siempre vuelve a donde entraste.

Con el idioma de catálogo en japonés, la lista muestra el nombre en inglés y debajo el título japonés.

### Identidades

Cada token es un usuario distinto del bridge: tiene su propio historial y sus propias preferencias (idioma de títulos, servidores por defecto, subtítulos, siguiente episodio y saltos de intro/outro). Dos dispositivos con el mismo token comparten ambos; otro token queda aislado. El servidor deriva la identidad del token y sólo guarda su hash con salt.

El token se guarda como elemento sincronizable del **Llavero de iCloud**, asociado a la URL normalizada del bridge. En un segundo dispositivo con el mismo Apple ID, prueba la misma URL y usa **Restaurar desde Llavero de iCloud**, o importa el token manualmente.

### Actualizaciones de la app

Al abrirse, la app consulta las releases de GitHub. Si hay una versión con IPA más nueva que la instalada, muestra los cambios de todas las versiones intermedias y ofrece:

- **Instalar con LiveContainer**: si la release incluye `manifest.plist`, prepara un enlace `itms-services` y lo envía a LiveContainer mediante `open-web-page`. Para releases anteriores usa `livecontainer://install?url=…`. Si LiveContainer no responde, ofrece descargar el IPA.
- **Ver la release en GitHub**.
- **Ahora no** u **Omitir esta versión**.

También puedes buscar actualizaciones desde **Configuración → Acerca de**.

El flujo con `open-web-page` y `itms-services` está pendiente de validación en iPhone/iPad cuando la app se ejecuta dentro de LiveContainer. No se debe dar por garantizado que el traspaso instale la actualización ni que conserve los datos: confirma en LiveContainer qué opción aparece antes de reemplazar la instalación y mantén un respaldo del token.

## Bridge

### Requisitos

- Node.js 24 LTS o posterior (o Docker).
- Acceso a Internet desde el bridge.
- Para uso en casa, el iPhone/iPad y el TV deben alcanzar la IP LAN del bridge; para uso remoto, ambos necesitan salida al dominio HTTPS.

### Variables de entorno

| Variable | Predeterminado | Uso |
| --- | --- | --- |
| `BRIDGE_HOST` / `BRIDGE_PORT` | `0.0.0.0` / `8787` | Interfaz y puerto de escucha. |
| `BRIDGE_ADMIN_TOKEN` | — | Activa las identidades: se usa una vez desde la app para registrar cada token. |
| `PROVIDER_TYPE` | `ANK` | Implementación del proveedor de catálogo (ver [Proveedores](#proveedores)). |
| `PROVIDER_ORIGIN` | origen incluido para `ANK` | Dominio del proveedor, por si el sitio se muda. |
| `DECLARE_AUDIO_LANGUAGE` | `true` | Con `false` deja de anunciar el idioma del audio en el manifiesto (para comparar comportamientos). |
| `HISTORY_STORE_PATH` | `proxy/data/history.json` | Historial por usuario. |
| `PREFERENCES_STORE_PATH` | junto a `history.json` | Preferencias por usuario. |
| `BRIDGE_USER_STORE_PATH` | `proxy/data/users.json` | Hash y salt de los tokens registrados. |

Sin `BRIDGE_ADMIN_TOKEN` ni usuarios registrados, el bridge funciona sin autenticación (sólo para tu red local).

### Proveedores

Todo lo específico del sitio de catálogo vive en un adaptador de proveedor dentro de [`proxy/server.mjs`](proxy/server.mjs); el resto del bridge (identidades, historial, preferencias y el proxy HLS con subtítulos) es común. Cada tipo implementa `watchUrl`, `search`, `latest`, `series`, `servers`, `source` y `segment`, descritos junto a `providerTypes`.

- **El sitio se muda de dominio con la misma estructura:** mantén `PROVIDER_TYPE=ANK` y define `PROVIDER_ORIGIN=https://nuevo-dominio`. El historial guarda la ruta `/watch/…` y se reubica sobre el origen nuevo, así que **Continuar viendo** sigue funcionando sin migraciones.
- **Otro sitio:** implementa un adaptador nuevo con la misma interfaz, regístralo en `providerTypes` con su propio tipo y selecciónalo con `PROVIDER_TYPE`.

`/health` informa el tipo activo (`{"ok":true,"provider":"ANK"}`); un `PROVIDER_TYPE` desconocido detiene el arranque con la lista de tipos admitidos.

### Ejecutar en local

```sh
cd proxy
npm ci
npm test
node server.mjs
curl http://127.0.0.1:8787/health   # {"ok":true,"provider":"ANK"}
```

Permite conexiones TCP entrantes al puerto `8787` y usa la IP LAN del equipo en la app con `http://`. La consola registra cada operación sin imprimir URLs temporales, tokens ni credenciales; tras **Probar y guardar** debe aparecer `[bridge] GET /health`.

### Docker con Apache (VPS)

El repositorio no incluye tus archivos de Docker; el bridge sólo necesita un contenedor que ejecute `node server.mjs` desde `proxy/` con Node 24, un volumen persistente para los JSON de datos y, opcionalmente, un `HEALTHCHECK`. Un ejemplo mínimo:

```dockerfile
FROM node:24-alpine
WORKDIR /app
COPY proxy/package.json proxy/package-lock.json proxy/.npmrc ./
RUN npm ci --omit=dev --ignore-scripts && mkdir -p /data && chown node:node /data
COPY proxy/server.mjs ./
USER node
ENV HISTORY_STORE_PATH=/data/history.json BRIDGE_USER_STORE_PATH=/data/users.json
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8787/health || exit 1
CMD ["node", "server.mjs"]
```

```yaml
services:
  bridge:
    build: .
    container_name: ani-bridge
    restart: unless-stopped
    environment:
      BRIDGE_ADMIN_TOKEN: ${BRIDGE_ADMIN_TOKEN}
    ports:
      - "127.0.0.1:8787:8787"
    volumes:
      - bridge-data:/data
volumes:
  bridge-data:
```

Apache publica HTTPS en `:443` y reenvía al puerto interno. `X-Forwarded-Proto` es necesario para que las URLs HLS que genera el bridge usen `https://`, y el formato de registro omite la query para no guardar tokens:

```apache
<VirtualHost *:443>
    ServerName bridge.midominio.com
    # SSLEngine y certificados como en el resto de tus sitios.
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    ProxyPass        / http://127.0.0.1:8787/ nocanon
    ProxyPassReverse / http://127.0.0.1:8787/
    CustomLog ${APACHE_LOG_DIR}/bridge.log "%h %t \"%m %U\" %>s %b"
</VirtualHost>
```

Para ver la consola del bridge dentro del contenedor (Ctrl+C sale sin detenerlo):

```sh
cd /opt/anksubbrd
DOCKER_CONFIG="$PWD/.docker" docker compose logs -f --tail 100   # o: docker logs -f --tail 100 ani-bridge
```

### Actualización automática del bridge

[`deploy/update-bridge.sh`](deploy/update-bridge.sh) automatiza el procedimiento manual (`git pull`, `docker compose up -d --build`, health check) siguiendo las etiquetas de versión:

1. Busca la etiqueta `vX.Y.Z` más reciente de `origin/main`; si ya está desplegada, termina sin hacer nada.
2. Avanza el checkout hasta esa etiqueta con `--ff-only`.
3. Sólo si cambió `proxy/`, ejecuta `docker compose up -d --build --remove-orphans` con `DOCKER_CONFIG=$PWD/.docker` y espera hasta 90 s a que `/health` responda y el contenedor esté `healthy`.
4. Si la salud falla, vuelve al commit anterior, reconstruye y marca esa etiqueta como fallida para no reintentarla en bucle (`FORCE=1` la reintenta).

Para ejecutarlo cada 15 minutos con systemd:

```sh
sudo cp /opt/anksubbrd/deploy/bridge-update.service.example /etc/systemd/system/bridge-update.service
sudo cp /opt/anksubbrd/deploy/bridge-update.timer.example /etc/systemd/system/bridge-update.timer
sudo systemctl daemon-reload
sudo systemctl enable --now bridge-update.timer
sudo systemctl start bridge-update.service    # primera ejecución manual
journalctl -u bridge-update.service -n 50
```

El servicio usa `/opt/anksubbrd`, el contenedor `ani-bridge` y `http://127.0.0.1:8787/health`; cámbialos en el archivo si tu instalación difiere. Debe ejecutarse con un usuario que pueda usar Docker y sea dueño del checkout; si lo ejecutas como `root` y el checkout pertenece a otro usuario, autoriza la ruta con `git config --global --add safe.directory /opt/anksubbrd`.

### Alternativa: systemd y Caddy sin Docker

1. Instala Node.js 24, clona el proyecto en `/opt/airplay-subtitle-bridge` y ejecuta `npm ci` dentro de `proxy`.
2. Crea el usuario de servicio y el archivo privado de entorno con el token administrador:

   ```sh
   sudo useradd --system --home /var/lib/airplay-subtitle-bridge --shell /usr/sbin/nologin airplaybridge
   sudo install -m 600 -o root -g airplaybridge /dev/null /etc/airplay-subtitle-bridge.env
   openssl rand -hex 32   # guárdalo como BRIDGE_ADMIN_TOKEN=… en ese archivo
   ```

3. Copia [`deploy/airplay-subtitle-bridge.service.example`](deploy/airplay-subtitle-bridge.service.example) a `/etc/systemd/system/airplay-subtitle-bridge.service` y actívalo con `sudo systemctl enable --now airplay-subtitle-bridge`.
4. Usa [`deploy/Caddyfile.example`](deploy/Caddyfile.example) con tu dominio; Caddy obtiene el certificado y conserva los encabezados necesarios.

No expongas el puerto `8787` directamente a Internet ni actives registros que incluyan la query de las URLs de reproducción.

### API

La app usa estas rutas; no necesitas llamarlas manualmente.

- `GET /health`
- `GET /api/search?q=titulo`
- `GET /api/latest?page=1&season=winter&status=currently-airing` (filtros paginados; `q` busca por título)
- `POST /api/series` con `{ "watchUrl": "…" }`
- `GET /api/series/:seriesKey/servers?episode=2`
- `POST /api/play` con `{ "seriesKey": "…", "episode": 2, "serverIndex": 0 }`
- `GET` / `PUT /api/history`: historial privado; se conserva el episodio más reciente de cada serie y los borrados se sincronizan.
- `GET` / `PUT /api/preferences`: preferencias privadas; gana la modificación más reciente.
- `POST /api/admin/users` con el encabezado `X-Bridge-Admin-Token`: registra un token de usuario.

Las sesiones de serie caducan a los 20 minutos (HTTP 410); la app recarga la serie y reintenta sola. El bridge sólo acepta URLs `/watch/…` del origen configurado y no expone un proxy genérico.

## Versiones y releases

[`version.txt`](version.txt) es la única fuente de la versión. [`scripts/version.mjs`](scripts/version.mjs) la lee y la sube, y sincroniza `MARKETING_VERSION` del proyecto Xcode y `version` de `proxy/package.json` y su lock; el bridge la informa en `/health`. Otros scripts (por ejemplo, un empaquetado) pueden leer `version.txt` directamente.

Tareas de VS Code (**Terminal → Ejecutar tarea**):

| Tarea | Efecto |
| --- | --- |
| **Versión: mostrar actual** | Imprime `version.txt`. |
| **Versión: subir parche / menor / mayor** | `0.2.3` → `0.2.4` / `0.3.0` / `1.0.0` en `version.txt` y los proyectos. Incluye esos archivos en tu siguiente commit. |
| **Versión: sincronizar proyectos** | Copia `version.txt` a los proyectos si los editaste a mano. |
| **Git: activar hook de version** | Una vez por clon: activa `.githooks` y `push.followTags`. |
| **Git: probar versionamiento** | Ejecuta el hook real en un repositorio temporal. |
| **Git: publicar commits y releases** | `git push --follow-tags origin HEAD`. |

El hook `post-commit` actúa sólo en tu clon local:

- Si el commit **no** cambia `version.txt`, sube el parche, lo incluye en ese mismo commit (amend, sin tocar el mensaje) y crea la etiqueta anotada `vX.Y.Z`.
- Si el commit **ya** cambia la versión (porque usaste una tarea de subir menor o mayor), conserva esa versión y sólo la etiqueta.
- Si enmiendas un commit aún no publicado, su etiqueta se mueve al commit nuevo; las etiquetas ya publicadas nunca se mueven.
- Durante rebase, merge o cherry-pick no hace nada. Si subiste la versión con una tarea pero no incluiste los archivos en el commit, avisa y no etiqueta.

Usa mensajes de [Conventional Commits](https://www.conventionalcommits.org/). Ejecuta `git fetch --tags` antes de trabajar en otro clon.

Al subir una etiqueta, [`.github/workflows/ios-build.yml`](.github/workflows/ios-build.yml) compara el commit con la etiqueta anterior:

| Cambió | Resultado |
| --- | --- |
| `ios/` | Compila el IPA sin firmar (artefacto y asset de la release) y publica la release como **latest**. |
| Sólo `proxy/` | Prueba el bridge y publica una release `vX.Y.Z (bridge)` sin IPA, que nunca se marca como latest. |
| Ninguno de los dos | No publica release. |

Así `https://github.com/rsilva48/anksubbrd/releases/latest/download/AirPlaySubtitlePlayer-unsigned.ipa` siempre apunta a un IPA y la app no ofrece actualizaciones que sólo tocaron el bridge. Las notas se agrupan en **App iOS**, **Bridge** y **Repositorio**; las de una release de la app incluyen todo lo ocurrido desde el IPA anterior. **Actions → Build iOS app → Run workflow** compila siempre, sin publicar release.

### Compilación iOS

La app requiere iOS/iPadOS 26 y usa los componentes nativos de Liquid Glass. El workflow selecciona la versión estable más reciente de Xcode instalada en el runner, así que compila con el SDK de iOS 27 en cuanto la imagen de GitHub incluya Xcode 27; el paso **Select Xcode** muestra la versión y el SDK usados. Para fijar una versión instalada, define la variable de repositorio `XCODE_VERSION` (por ejemplo `26.6`).

El IPA no está firmado: impórtalo en LiveContainer o fírmalo con tu herramienta de sideload (por ejemplo ByteLoader).

### Página de instalación con GitHub Pages

La página está en [`docs/index.html`](docs/index.html). Las notas de cada release de app incluyen un enlace HTTPS a la página con `?tag=vX.Y.Z`, además del enlace para descargar directamente la IPA. La página ofrece enlaces para instalar con LiveContainer y para descargar el archivo; sin parámetro `tag`, usa los assets de la última release de app marcada como `latest`.

Para publicarla:

1. Incluye `docs/index.html`, el workflow y los cambios de la app en el commit, y sube el commit y su etiqueta.
2. En GitHub, abre **Settings → Pages → Build and deployment**. Elige **Deploy from a branch**, la rama `main` y la carpeta `/docs`, y guarda. La dirección prevista es `https://rsilva48.github.io/anksubbrd/`.
3. En la nueva release de app, comprueba que se hayan publicado **ambos assets**, `AirPlaySubtitlePlayer-unsigned.ipa` y `manifest.plist`, y que el enlace de las notas lleve a la página con la etiqueta correcta. El workflow genera el manifiesto con la URL del IPA de esa versión; las releases antiguas no reciben el manifest automáticamente.
4. Prueba por separado el enlace desde la página y el botón de actualización de la app. El primero pasa por GitHub Pages; el segundo construye directamente el enlace para LiveContainer. Verifica el comportamiento con la app invitada abierta, el diálogo de reemplazo y la conservación de sus datos. Si no funciona, descarga el IPA desde la release e impórtalo manualmente.

## Límites técnicos

- Si una fuente no entrega HLS y VTT, no puede convertirse en subtítulos AirPlay.
- No se admiten DRM, paywalls ni mecanismos que impidan al receptor AirPlay recuperar el manifiesto.
- HTTP sólo funciona dentro de la red local; para un dominio público usa HTTPS.
- No se inicia sesión en el sitio de origen: el progreso compartido vive en tu bridge, protegido por token.
