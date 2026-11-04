# AniBridge Player

App personal para iPhone/iPad (iOS/iPadOS 26 o posterior) y Android TV que navega un catálogo de anime a través de un bridge propio. En iPhone y iPad reproduce el episodio elegido y lo envía por AirPlay con los subtítulos como pistas HLS reales. El bridge también guarda, por identidad, el progreso de **Continuar viendo** y las preferencias de catálogo y reproducción.

La versión para teléfonos Android está en desarrollo: la misma APK detecta si se ejecuta en un teléfono y presenta una interfaz táctil Material 3. Esta primera etapa requiere Android 8 o posterior y permite conectar un bridge con una identidad existente, consultar el historial, explorar recientes y buscar, abrir episodios y reproducirlos. Aún no tiene todas las funciones de iOS; el token se guarda cifrado con Android Keystore y debe respaldarse por separado para restaurarlo en otro dispositivo.

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

Las apps (iOS, Android TV y Android en teléfono) están en español y en inglés: usan el idioma del dispositivo, en español si es español y en inglés en cualquier otro caso. En iOS y en Android 13+ el idioma de la app también se puede elegir en los ajustes del sistema. La página `/setup` del bridge sigue el idioma del navegador.

1. Instala el IPA (ver [Releases](#versiones-y-releases)).
2. En el primer uso, **Buscar**, **Recientes** y **Continuar** permanecen bloqueados y ofrecen un acceso directo a **Ajustes**.
3. En **Ajustes → Bridge** elige `https://` (predeterminado) o `http://` y escribe sólo el dominio o la IP, con puerto si hace falta (`bridge.midominio.com` o `192.168.1.20:8787`). Si pegas una dirección con `http://` o `https://`, el prefijo se quita del campo y el selector adopta ese protocolo. **Probar y guardar** activa la dirección únicamente si `/health` responde.
4. Si el bridge requiere identidad, créala, restáurala desde el Llavero de iCloud o importa un token (ver [Identidades](#identidades)).
5. Busca una serie (al abrir **Buscar** el campo se activa con el teclado) o entra en **Recientes**, que sigue los estrenos del tipo configurado (`Sub` o `Dub`; el selector de la barra permite cambiar a Sub, Dub o ambos). Cada póster muestra el episodio más reciente, el total si se conoce, los episodios en Dub y una marca **+18** en series R+ o Rx (**Ajustes → Catálogo → Ocultar series +18** las quita de Recientes y Buscar). La búsqueda usa la página de filtros del catálogo, con todos los resultados paginados. Los **Filtros** (género, temporada, año, estado, tipo, origen y clasificación) admiten varias opciones por categoría; además hay orden, número de episodios y puntuación mínima. Las opciones (con los géneros del catálogo, ocultando los +18 si así está configurado) las publica el bridge en `GET /api/catalog/filters`. En iPhone el botón está sobre los resultados de la búsqueda. En Android TV, **Buscar** empieza por los filtros: se eligen, se escribe un título si se quiere y se pulsa **Buscar**; con sólo filtros también busca. El campo de título no abre el teclado hasta pulsar OK, así el control remoto puede moverse entre los botones. La ficha de la serie muestra la sinopsis, el estado de emisión y las temporadas relacionadas según el orden de visionado del catálogo. Elige episodio y servidor (`Sub` o `Dub`; el predeterminado está en Ajustes).

### Reproductor

- El vídeo ocupa siempre toda la pantalla; los controles flotan encima con Liquid Glass y nunca lo redimensionan.
- Un toque muestra u oculta todos los controles a la vez; se ocultan solos tras unos segundos de reproducción.
- Doble toque en la mitad izquierda o derecha retrocede o adelanta 10 s (se acumula si repites). Deslizar en vertical en la mitad izquierda cambia el brillo y en la derecha el volumen; con los controles visibles también aparecen las barras de brillo (izquierda) y volumen (derecha), salvo en iPhone vertical, donde se muestran sólo al ajustar.
- Con teclado físico: espacio reproduce/pausa, ← → retroceden/adelantan 10 s y ↑ ↓ cambian el volumen.
- Al terminar el último episodio disponible (del tipo Sub o Dub que estabas viendo) el reproductor se cierra solo.
- Incluye AirPlay, imagen dentro de imagen, ±10 s, episodio anterior/siguiente sin cerrar el reproductor, un panel de subtítulos, audio y velocidad, ajuste/relleno de pantalla (también con gesto de pellizco) y botones **Saltar intro/outro**.
- Sub activa los subtítulos automáticamente: el idioma elegido en **Subtítulos en Sub**, si no el idioma del dispositivo y, si no existe, la pista predeterminada del bridge (inglés). Cambiar de subtítulo durante un episodio Sub actualiza esa preferencia.
- Los controles de la pantalla bloqueada y del Centro de control funcionan mientras se reproduce por AirPlay.

- **Versión** (en el panel de subtítulos y audio): cambia entre Sub y Dub en el mismo punto del episodio, prefiriendo un servidor con el mismo nombre.
- **Google Cast**: el botón Cast del reproductor envía el episodio a un Chromecast o Google TV (ver [Google Cast](#google-cast)). AirPlay sigue siendo independiente.

Usa el botón AirPlay del reproductor, no **Duplicar pantalla**: la app configura la sesión de vídeo de larga duración para que el TV reciba vídeo, audio y pistas VTT.

### Pantallas anchas (iPhone Duo, iPad)

Con pantalla ancha (el iPhone Duo abierto, iPad o un iPhone grande en horizontal), Recientes, Buscar y Continuar muestran la lista a la izquierda y la ficha de la serie a la derecha. Plegado o en vertical, cada pestaña es una sola columna como siempre.

- La disposición depende de la clase de tamaño horizontal (`regular` o `compact`), no del modelo: el iPhone Duo abierto se identifica como iPhone, pero su pantalla interior es `regular`. Por eso los títulos de las pestañas son compactos en cualquier pantalla ancha, igual que en iPad.
- Las columnas y lo que queda detrás de ellas comparten el mismo fondo (`systemGroupedBackground`, con `containerBackground(_:for: .navigation)`). La pestaña que se abre por primera vez coloca su columna bajo la barra de pestañas flotante en dos pasos, y antes dejaba ver una franja negra arriba a la izquierda (capturas del 3 de noviembre en Continue). Ahora ese primer paso ya tiene el color definitivo.
- El iOS 27.1 SDK trae APIs propias del iPhone Duo (`ArrangementView`, `ReservedRegion`, barras verticales en la columna de detalle). La app no las necesita: `NavigationSplitView` ya ajusta las columnas al pliegue y las barras verticales.

### Continuar viendo

Guarda la serie, episodio, servidor, tipo (Sub/Dub) y segundo actual de las últimas 50 series. **Continuar** reanuda directamente con el mismo servidor y tipo. Un episodio cuenta como visto al llegar al outro o a sus últimos minutos; entonces la serie ofrece el siguiente episodio del mismo tipo en lugar de reabrir el final del anterior.

La lista se divide en **Nuevos episodios** (arriba: terminaste el último episodio que viste y ya salió el siguiente), **En curso** (incluye, si terminaste la serie, una temporada siguiente por empezar), **Al día** (viste el último episodio emitido y la serie sigue en emisión) y **Completados**. Los episodios nuevos se cuentan sólo en el tipo que estabas viendo: un estreno en Dub no aparece si ves la serie en Sub. Al abrir una serie, el botón **Continuar** aparece en la temporada que tenga progreso; cambiar de temporada actualiza la misma pantalla, así que **Atrás** siempre vuelve a donde entraste.

Con el idioma de catálogo en japonés, la lista muestra el nombre en inglés y debajo el título japonés.

En Android TV, Continuar, Recientes y Buscar muestran los pósters en la misma cuadrícula que se recorre hacia abajo. Continuar usa las mismas secciones y avisos que el iPhone (**Nuevos episodios** con «Nuevo: episodio N», **En curso** con «Nueva temporada», **Al día** con la fecha estimada del próximo episodio, **Completados**). Mantener pulsado OK sobre una serie de Continuar abre un menú para abrirla o **quitarla de Continuar** (se quita también en el teléfono y en las demás TVs de esa identidad). En la ficha, la fila de temporadas indica cuál es la actual y cuántas hay («1 de 16»), y sus bordes se difuminan con ‹ › cuando hay más a los lados.

### Descargas sin conexión

Cada episodio de la ficha tiene su botón de descarga (también al mantenerlo pulsado, en Sub o Dub). El botón **Descargar** de la barra ofrece el siguiente episodio sin ver, los siguientes 3 y **los que faltan** desde el que estás viendo (o la **serie completa** si aún no la empezaste). La descarga guarda el HLS completo: vídeo, audio y todas las pistas de subtítulos, en un paquete nativo de iOS que sigue bajando con la app en segundo plano.

- Antes de descargar eliges el servidor, igual que al reproducir. Si en algún episodio ese servidor no existe o no responde, se prueba automáticamente otro del mismo tipo (Sub o Dub); un episodio sin ninguno de ese tipo se omite. La ficha avisa de cada caso y **Descargas** muestra el servidor de cada episodio.
- Si una descarga falla a mitad de camino, se reinicia sola con el siguiente servidor del mismo tipo que aún no se probó, hasta agotarlos.
- La pestaña **Descargas** funciona sin red y sin bridge configurado. Al reproducir desde ahí, el siguiente episodio es la siguiente descarga de la misma serie y tipo.
- En la ficha de la serie, un episodio descargado se reproduce desde el dispositivo. **Elegir servidor en línea** fuerza el streaming.
- Las portadas se guardan en el dispositivo (las de **Continuar viendo**, las de las descargas y las que ves en el catálogo), así que se muestran en modo avión. Las que no se usan en 60 días se borran solas.
- La ficha de cada serie que abres se guarda (sinopsis, episodios y temporadas). Sin conexión, al abrir una serie desde **Continuar viendo** se muestra esa copia y sólo se pueden reproducir los episodios descargados; si nunca se guardó, se listan sólo los descargados.
- Al abrir **Descargas**, una descarga que terminó mientras la app estaba cerrada (y quedó marcada como interrumpida) se recupera si el paquete está completo. Si el archivo de una descarga no aparece o quedó incompleto, la app lo indica, con la ruta, en lugar de no hacer nada.
- Sin conexión, cada pantalla lo indica en lugar de mostrar un error de red: el catálogo ofrece ir a **Descargas** y se recarga solo al volver la red, **Continuar viendo** avisa que el progreso se sincronizará después y un episodio sin descargar explica que necesita conexión. El aviso del permiso de **Red local** sólo aparece si hay red pero no se llega a un bridge con IP local.
- El progreso visto sin conexión se guarda en el dispositivo (también si cierras la app) y se envía al bridge en cuanto vuelve la conexión, o al abrir la app con red.
- Con **Ajustes → Este dispositivo → Borrar descargas ya vistas** (activado por defecto), una descarga se elimina sólo cuando terminas de ver ese mismo episodio (al llegar al outro o a sus últimos minutos), en este u otro dispositivo con la misma identidad. Abrir otro episodio sin terminar el anterior no borra nada. La limpieza ocurre al cerrar el reproductor y al abrir la app o la pestaña.
- El bridge debe responder mientras se descarga: cada episodio se resuelve en línea y el bridge conserva la fuente durante dos horas. Una descarga fallida se reintenta deslizando a la derecha en **Descargas**.
- El CDN limita las peticiones por IP. El bridge las envía a un ritmo fijo (`UPSTREAM_RATE`) y, si aun así recibe un 429, pausa todo el tráfico durante el `Retry-After` antes de reintentar. Un episodio tarda alrededor de un minuto en descargarse; varios a la vez se reparten ese ritmo.

### Avisos de nuevos episodios

La primera vez que abres la app con un bridge configurado, te pregunta si quieres estos avisos; también se activan o desactivan en **Ajustes → Este dispositivo → Avisar de nuevos episodios**. La app programa notificaciones locales para los episodios que estrenan en los próximos 8 días, según el horario estimado del catálogo. Sólo avisa de las series de **Continuar viendo**, cuando el episodio es posterior al que viste y del mismo tipo (Sub o Dub) que sigues. La notificación llega unos minutos después de la hora estimada. Al tocarla, con la app cerrada, en segundo plano o abierta:

- La app abre la serie y comprueba en el bridge que ese episodio esté publicado en el tipo anunciado (Sub o Dub).
- Si lo está, abre directamente el reproductor. Usa la descarga si la hay; si no, el servidor que usaste por última vez en la serie, si tiene ese tipo, o cualquier otro servidor del mismo tipo. Nunca cambia a la otra versión.
- Si el episodio aún no está publicado o no tiene servidores de ese tipo, se queda en la lista de episodios con un aviso. Si no hay conexión con el bridge, el episodio se abre solo en cuanto vuelve.
- Los avisos programados antes de esta versión sólo llevan la serie: se actualizan solos la próxima vez que abras la app.

- Los avisos se reprograman al abrir o volver a la app (y al sincronizar el historial), así que basta con abrirla de vez en cuando. No requieren servidor de push: el push remoto (APNs) exigiría una app firmada con ese permiso, algo que un IPA sin firmar instalado con LiveContainer no tiene.
- El horario es una estimación y por ahora el catálogo sólo publica horarios de Sub.
- La ficha de la serie muestra la fecha del **Próximo episodio**, y las series **Al día** de **Continuar viendo** también la muestran.

### Traducción de la sinopsis

El botón **Traducir** de la sinopsis usa la traducción integrada de iOS (en el dispositivo) para pasarla del inglés al idioma del sistema; la primera vez iOS puede pedir descargar los idiomas. **Ajustes → Este dispositivo → Traducir sinopsis automáticamente** la traduce al abrir cada serie.

### Identidades

Cada token es un usuario distinto del bridge: tiene su propio historial y sus propias preferencias (idioma de títulos, servidores por defecto, subtítulos, siguiente episodio y saltos de intro/outro). Dos dispositivos con el mismo token comparten ambos; otro token queda aislado. El servidor deriva la identidad del token y sólo guarda su hash con salt.

El token se guarda como elemento sincronizable del **Llavero de iCloud**, asociado a la URL normalizada del bridge. En un segundo dispositivo con el mismo Apple ID, prueba la misma URL y usa **Restaurar desde Llavero de iCloud**, o importa el token manualmente.

### Actualizaciones de la app

Al abrirse, la app consulta las releases de GitHub. Si hay una versión con IPA más nueva que la instalada, muestra los cambios de todas las versiones intermedias y ofrece:

- **Instalar con LiveContainer**: si la release incluye `manifest.plist`, prepara un enlace `itms-services` y lo envía a LiveContainer mediante `open-web-page`. Para releases anteriores usa `livecontainer://install?url=…`. Si LiveContainer no responde, ofrece descargar el IPA.
- **Ver la release en GitHub**.
- **Ahora no** u **Omitir esta versión**.

También puedes buscar actualizaciones desde **Ajustes → Acerca de**.

### Fuente para LiveContainer

Para añadir el catálogo de esta app, abre **Sources → +** en LiveContainer y pega:

```text
https://github.com/rsilva48/anksubbrd/releases/latest/download/source.json
```

También puedes usar **Añadir fuente a LiveContainer** desde la página de instalación. Una vez publicada una release de app con la fuente, LiveContainer podrá cargar su ficha e iniciar la instalación desde Sources. Para buscar cambios, actualiza la fuente en LiveContainer; la instalación o sustitución seguirá requiriendo confirmación. La compatibilidad de actualización sobre una instalación existente y la conservación de datos dependen de LiveContainer y aún deben probarse en el dispositivo; respalda el token antes de reemplazar o borrar la app.

El workflow genera `source.json` junto al IPA de cada release de app, leyendo su `Info.plist`, tamaño y SHA-256 reales. El JSON apunta al IPA de esa versión y el enlace estable apunta al source de la última release de app. Las releases que solo cambian el bridge no sustituyen esa release. La URL del source comenzará a funcionar cuando se publique la primera release que incluya este cambio; no se añade retroactivamente a releases anteriores.

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
| `UPSTREAM_RATE` | `6` | Peticiones por segundo que el bridge envía al CDN, sumando todas las reproducciones y descargas. El CDN responde 429 a las ráfagas de una misma IP; bájalo si los logs muestran `is rate limiting`. |
| `UPSTREAM_CONCURRENCY` | `4` | Peticiones simultáneas al CDN. |
| `HISTORY_STORE_PATH` | `proxy/data/history.json` | Historial por usuario. |
| `PREFERENCES_STORE_PATH` | junto a `history.json` | Preferencias por usuario. |
| `BRIDGE_USER_STORE_PATH` | `proxy/data/users.json` | Hash y salt de los tokens registrados. |
| `LIVECONTAINER_BUNDLE_NAME` | `com.personal.airplaysubtitleplayer.app` | Carpeta de la app dentro de LiveContainer, para el enlace «abrirla por su nombre» de la página `/setup`. |

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
- `GET /api/latest?page=1&language=sub&season=fall&season=summer&year=2026&status=currently-airing` (filtros paginados; cada filtro se puede repetir para elegir varios valores; `q` busca por título; `language` es `sub`, `dub` o `all`)
- `POST /api/series` con `{ "watchUrl": "…" }` (incluye sinopsis, clasificación, estado, total de episodios, disponibilidad Sub/Dub por episodio y temporadas relacionadas)
- `GET /api/schedule`: estrenos estimados de los próximos 8 días (serie, episodio, tipo y hora Unix; caché de 30 min)
- `POST /api/series/status` con `{ "watchUrls": ["…"] }`: último episodio Sub y Dub, total, estado y temporada siguiente de hasta 50 series (caché de 15 min)
- `GET /api/series/:seriesKey/servers?episode=2`
- `POST /api/play` con `{ "seriesKey": "…", "episode": 2, "serverIndex": 0 }`
- `GET` / `PUT /api/history`: historial privado; se conserva el episodio más reciente de cada serie y los borrados se sincronizan.
- `GET` / `PUT /api/preferences`: preferencias privadas; gana la modificación más reciente.
- `POST /api/admin/users` con el encabezado `X-Bridge-Admin-Token`: registra un token de usuario.
- `POST /api/pair/start` y `GET /api/pair/status?pairingId=…` (sin identidad), `POST /api/pair/approve` con `{ "code", "label" }`: vinculación de la TV por QR.
- `GET /api/catalog/filters`: listas de filtros con etiquetas en español (`label`) y en inglés (`labelEn`) (`genres` con su `id` del catálogo y `adult`, `mediaTypes`, `sources`, `sorts`). `GET /api/latest` acepta además `genre=`, `source=`, `sort=`, `minEpisodes=` y `maxEpisodes=`.
- `POST /api/identities` con `{ "label" }`: crea un perfil nuevo con la identidad que hace la petición; responde `{ token, userId, label }`. `GET`/`POST /setup?code=…`: página para completar la vinculación de una TV desde el navegador.
- `GET /api/devices`: TVs conectadas de la identidad, con lo que reproducen, `stateAge` (ms desde ese informe) y `canOpen` (si la TV puede abrir la app sola). `PUT /api/devices/:id` con `{ "name", "state", "canOpen" }`: la TV informa su estado. `GET /api/devices/:id/commands`: la TV espera órdenes (long polling de hasta 25 s). `POST /api/devices/:id/commands` con `{ "type": "play" | "pause" | "resume" | "toggle" | "seek" | "skip" | "next" | "previous" | "stop" | "volume" | "subtitles", … }`: el teléfono envía una orden (`play` lleva `watchUrl`, `episode` y `kind`; `seek`, `position` absoluta o `seconds` relativos; `volume`, `steps`; `subtitles`, `track` con el id de una pista de `state.subtitles` u `off`).

- `POST /api/cast` con `{ "playbackUrl" }`: crea un enlace temporal de Google Cast para una reproducción de la misma identidad. Responde `{ id, url, contentType, subtitles: [{ id, name, language, url, forced, default }], expiresAt }`. `DELETE /api/cast/:id` lo revoca. `GET /cast/:id/master.m3u8`, `/cast/:id/media?url=…&sig=…` y `/cast/:id/subtitle/:n.vtt` sirven el manifiesto, los segmentos y los WebVTT al receptor, con CORS y sin token de identidad.

Las sesiones de serie caducan a los 20 minutos (HTTP 410); la app recarga la serie y reintenta sola. El bridge sólo acepta URLs `/watch/…` del origen configurado y no expone un proxy genérico.

### Control de la TV desde el teléfono

La app de Android TV aparece como TV conectada para las apps que usan la misma identidad (el mismo bridge y token), también con la app cerrada: un servicio en primer plano arranca al encender la TV, tras cada actualización y al abrir la app, y sigue el perfil activo. En el iPhone:

- **Ver en TV** (en Continuar viendo o en la barra de una serie) abre el control remoto de la TV conectada. La primera vez se elige la TV; la app la recuerda y la usa siempre hasta pulsar **Desconectar**. Abrir el control solo muestra el estado de la TV: no envía nada. Desde una serie ofrece **Reproducir en la TV** con el episodio en curso o el siguiente.
- Con una TV conectada, **reproducir en la ficha de una serie** (Continuar, el siguiente episodio, tocar un episodio) lo envía a la TV y abre el control remoto; los botones muestran el icono de TV. Si la TV no está disponible, el control ofrece **Reproducir en este iPhone**. Siguen siendo locales «Ver en este iPhone» (menú del episodio), «Elegir servidor en línea», las descargas y todo sin conexión. Si la TV ya muestra ese episodio, no se reinicia.
- Con una TV conectada, mientras la TV tiene un episodio (reproduciendo o en pausa), el iPhone lo muestra como **reproducción en curso**: en la pantalla bloqueada, el Centro de control y los auriculares se ve el anime y el episodio, y play/pausa, ±10 s, anterior/siguiente y la barra de progreso controlan la TV. Para que iOS lo permita, la app reproduce un audio silencioso mientras tanto (interrumpe la música de otras apps, como cualquier reproductor); se detiene cuando la TV se detiene, al desconectarte o al reproducir algo en el iPhone.
- Con una TV conectada y nada reproduciéndose en el iPhone, **las teclas de volumen cambian el volumen de la TV** (como con Chromecast), también con la pantalla bloqueada mientras la TV muestra un episodio; el volumen del iPhone vuelve a donde estaba. En la TV es el volumen del sistema: en un televisor con Google TV, el del propio televisor; en un box HDMI, Android lo reenvía al televisor por HDMI-CEC (si el televisor no responde a CEC, no cambia).

El control remoto muestra lo que reproduce la TV, con una barra de progreso que se puede arrastrar para ir a un punto exacto, y permite pausar o reanudar, ±10 s, saltar intro/outro cuando la TV lo ofrece, elegir los subtítulos (o desactivarlos; el idioma elegido sigue en los episodios siguientes), subir o bajar el volumen, episodio anterior o siguiente y detener. Las órdenes pasan por el bridge, así que funcionan aunque el teléfono y la TV no estén en la misma red. Una TV que deja de informar durante 45 s desaparece de la lista.

Para que el teléfono pueda **abrir** la app de la TV cuando está cerrada, Android exige el permiso «Mostrar sobre otras apps»; la app de la TV muestra el botón **Abrir desde el teléfono**, que explica y abre ese ajuste. Sin él, la TV solo empieza episodios con la app en pantalla (el teléfono lo indica). En TV TCL, el «Escudo de autorización» del Administrador de TV bloquea el arranque automático de apps instaladas a mano: tras encender la TV hay que abrir la app una vez (después sigue disponible en segundo plano), salvo que se permita en Administrador de TV › Escudo de autorización › Permiso de lanzamiento automático.

### Perfiles de la TV

- **Vincular perfil** muestra un código QR que abre la página `/setup` del bridge en cualquier teléfono, sin instalar nada. Desde ahí se puede abrir la app («Abrir en la app», que vincula la TV con la identidad del teléfono), pegar un token existente o, la primera vez, crear la identidad con el token administrador del bridge. El token administrador sólo se comprueba, no se guarda; cada código admite cinco intentos y caduca a los 10 minutos.
- **LiveContainer**: iOS no conoce los esquemas de URL de las apps que viven dentro de LiveContainer, así que «Abrir en la app» sólo funciona con la IPA instalada directamente. La página ofrece además **Abrir en LiveContainer** (`livecontainer://open-url?url=<Base64 del enlace anksubbrd://pair…>`): LiveContainer busca entre sus apps la que declara el esquema `anksubbrd` y le entrega el enlace. Debajo hay un enlace alternativo, «abrirla por su nombre» (`livecontainer://livecontainer-launch?bundle-name=com.personal.airplaysubtitleplayer.app&open-url=…`), útil si otra app de LiveContainer está abierta. Si LiveContainer renombró la carpeta de la app (por ejemplo, al instalarla dos veces), configura ese nombre en `LIVECONTAINER_BUNDLE_NAME`. La forma más directa sigue siendo escanear desde la app: **Ajustes › Escanear código de la TV…**, que lee el QR de la TV sin pasar por iOS. Dentro de LiveContainer, la app lo recuerda debajo de ese botón.
- **Crear perfil** crea un perfil nuevo con la identidad del perfil activo, sin token administrador (`POST /api/identities`, como mucho 10 perfiles por identidad y 5 por hora).
- Manteniendo OK sobre un perfil: **Llevar al teléfono** muestra, tras un aviso, un QR con su identidad (`anksubbrd://identity?…`) que se oculta en un minuto; **Quitar** lo borra de la TV.
- En el iPhone, ese QR se abre con la app Cámara (sólo con la IPA instalada directamente) o con **Ajustes › Escanear código de la TV…** (también dentro de LiveContainer), que también lee los códigos de vinculación. Usar el perfil reemplaza la identidad actual (pide confirmar que guardaste su token) y, si el código es de otro bridge, lo prueba y se conecta a él.

### Android (teléfono)

El mismo APK (`AniBridgePlayer-TV.apk`) instalado en un teléfono abre la app de teléfono, con Material You (los colores del fondo de pantalla en Android 12+). Tiene las mismas pestañas que iOS: Recientes, Continuar, Descargas, Ajustes y Buscar, cada una con su propia navegación.

- **Catálogo**: cuadrícula de pósters con el episodio más reciente, Dub y +18; Sub/Dub/ambos en Recientes; búsquedas recientes; los mismos filtros (género, temporada, año, estado, tipo, origen, clasificación, orden, episodios y puntuación).
- **Ficha**: el mismo botón principal que iOS (continuar, siguiente, temporada siguiente, volver a ver), temporadas en un menú, episodios con progreso y menú (Descargar en Sub/Dub, Ver sin conexión, Ver en TV, Ver en este teléfono, Elegir servidor) y el selector de servidores Sub/Dub. **Traducir** abre la sinopsis en el traductor del sistema (Google Traductor u otra app que traduzca texto).
- **Continuar**: las mismas secciones (Nuevos episodios, En curso, Al día, Completados); manteniendo pulsada una serie se quita (también en los demás dispositivos).
- **Reproductor**: horizontal a pantalla completa con los controles de Media3 (subtítulos, audio y velocidad en sus ajustes), episodio anterior/siguiente del mismo tipo, saltar intro/outro (y el salto automático), siguiente episodio automático y el progreso sincronizado. Un subtítulo elegido en un episodio Sub queda como preferencia de la identidad, como en iOS. Al salir de la app mientras reproduce sigue en **imagen dentro de imagen** (con reproducir/pausa); cerrar esa ventana o bloquear el teléfono pausa.
- **Descargas**: como en iOS, cada episodio se guarda con todos sus subtítulos, por dispositivo (no por identidad). Se descargan desde el menú de un episodio o desde el botón de descarga de la ficha (el siguiente episodio, los 3 siguientes o los que faltan); cada episodio usa un servidor que funcione del tipo elegido. La pestaña Descargas las agrupa por serie, con progreso, espacio usado, reintentar con otro servidor y borrar. Un episodio descargado se reproduce desde el teléfono sin conexión (también desde la ficha y al pasar al siguiente episodio). Sin conexión con el bridge, la ficha muestra solo los episodios descargados. Con **Borrar descargas ya vistas** (activado por defecto), una descarga se borra al terminar ese episodio aquí o en otro dispositivo con la misma identidad. El progreso guardado sin conexión se sube al bridge al volver la conexión.
- **TV**: la misma TV conectada y el mismo control remoto que iOS; con una TV conectada, reproducir envía el episodio a la TV, y las teclas de volumen cambian el volumen de la TV mientras no se reproduce nada en el teléfono.
- **Códigos QR**: **Ajustes → Escanear código de la TV…** usa el escáner de Google Play services (sin permiso de cámara) para el código de un perfil («Llevar al teléfono») o de vinculación de una TV. La app Cámara también abre esos códigos (`anksubbrd://identity`, `anksubbrd://pair` y la página `/setup` del bridge).
- **Avisos de nuevos episodios**: la primera vez la app ofrece activarlos (pide el permiso de notificaciones en Android 13+). Avisan, a la hora estimada del catálogo más 5 minutos, de los episodios nuevos de las series de Continuar en el tipo Sub o Dub que sigues; tocar el aviso abre la serie. Se reprograman cada vez que la app vuelve al frente.
- **Ajustes**: bridge, identidad privada (crear con el token administrador, importar, respaldar, cambiar; el token se guarda cifrado con Android Keystore), preferencias sincronizadas, este dispositivo (avisos y descargas) y actualizaciones desde GitHub.

- **Google Cast**: botón Cast en el reproductor, con el selector de dispositivos de la app, y un panel de control mientras se transmite (ver [Google Cast](#google-cast)). El menú **Sub ▾ / Dub ▾** del reproductor cambia de versión en el mismo punto del episodio.
- **Plegables, tablets y ventanas redimensionables**: usa la clase de tamaño de ventana y la postura de Jetpack WindowManager (a través de `androidx.compose.material3.adaptive`). En ventanas compactas (menos de 600 dp) mantiene la barra inferior y un solo panel. Desde 600 dp (un plegable abierto, una tablet, pantalla dividida) muestra un riel de navegación y la lista junto a la ficha de la serie. Si hay un pliegue vertical, los dos paneles se separan justo en él, así que la bisagra no tapa contenido. En postura de mesa (medio plegado en horizontal), el reproductor pone el vídeo en la mitad superior y el título, la versión, Cast y el episodio anterior/siguiente en la inferior. Al plegar, desplegar o girar se conservan la pestaña, la serie abierta, la lista de cada pestaña y la reproducción: la actividad gestiona los cambios de tamaño sin recrearse. En teléfonos sin pliegue y en Android antiguo (desde Android 8) todo sigue como antes.

Pendiente: los controles en la pantalla de bloqueo (el reproductor del teléfono se pausa al bloquear).

## Google Cast

Desde el reproductor del iPhone o iPad (SDK oficial de Google Cast 4.8.6 por Swift Package Manager) y del teléfono o tablet Android (`play-services-cast-framework` 23.0.0) se puede enviar el episodio a un Chromecast, un Google TV o una TV con Chromecast integrado. Se usa el receptor predeterminado de Google (Default Media Receiver, `CC1AD845`): no hace falta registrar nada en la consola de Google Cast.

- **Cómo funciona**: al conectar un dispositivo, la app pide al bridge un enlace temporal para el episodio (`POST /api/cast`) y se lo envía al receptor con el HLS (segmentos MPEG-TS) y los subtítulos como pistas WebVTT laterales. El reproductor del teléfono se detiene, para no descargar el vídeo dos veces, y pasa a ser el mando.
- **Controles**: reproducir y pausar, ±10 s, barra de posición, subtítulos (o ninguno), episodio anterior y siguiente, siguiente episodio automático, saltar intro y outro, volumen del dispositivo y dejar de transmitir. El progreso se guarda en Continuar como al ver en el teléfono. En iPhone, el botón Cast del SDK también muestra el dispositivo, su volumen y el botón para desconectar.
- **Audio**: el receptor predeterminado sólo deja al emisor cambiar pistas de texto; el audio de un HLS lo elige el propio receptor. Por eso el audio se cambia con **Versión** (Sub: japonés con subtítulos; Dub: inglés), que carga la otra versión en el mismo punto. Para elegir pistas de audio dentro del mismo stream haría falta un receptor propio (Custom Web Receiver) registrado en la consola de Google Cast.
- **Sesiones**: si la app pasa a segundo plano, el receptor sigue reproduciendo; al volver, la sesión se reanuda sin recargar el episodio. Si la sesión termina (desde la app, el SDK o la TV), el episodio sigue en el teléfono, en pausa, donde lo dejó el receptor. Cerrar el reproductor no detiene la TV.
- **Las descargas** se reproducen siempre en el teléfono: el receptor necesita el bridge.

### Seguridad y red

- El receptor nunca recibe el token de identidad, que no se puede revocar. Recibe un id aleatorio de 192 bits que sólo abre esa reproducción (manifiesto, segmentos firmados y sus WebVTT), caduca con ella (2 horas) y se revoca al terminar la sesión Cast. Mientras es válido, quien tenga el enlace puede ver ese episodio.
- Las respuestas de `/cast/…` llevan `Access-Control-Allow-Origin: *` (no usan cookies ni credenciales) y responden a `OPTIONS`, como pide el receptor web.
- **El dispositivo Cast tiene que poder abrir la dirección del bridge que usa el teléfono**. Con un bridge en la red de casa (`http://192.168.x.x:8787`) funciona si la TV está en esa misma red. Con un bridge público, usa HTTPS con un certificado válido. Google no garantiza que el receptor cargue HLS por `http://`; si el receptor no reproduce, prueba con la dirección HTTPS del bridge.
- **iOS**: la búsqueda de dispositivos usa la red local (`NSLocalNetworkUsageDescription`, `NSBonjourServices` con `_googlecast._tcp` y `_CC1AD845._googlecast._tcp`). iOS pide el permiso de red local la primera vez que se toca el botón Cast. No hace falta el permiso de multicast.
- **Android**: el selector de dispositivos es propio (Material 3 sobre MediaRouter), así que la actividad no necesita AppCompat. Requiere Google Play services.

### Qué falta comprobar en dispositivos reales

- Nada de Cast se ha probado todavía contra un receptor real. Cubren el bridge pruebas automáticas, incluida una petición HTTP real a `/cast` (CORS, `OPTIONS`, WebVTT y firma). La app Android compila; en el emulador se comprobaron el botón y el diálogo de búsqueda, pero el emulador no ve dispositivos Cast de la red. El código de iOS sólo pasa el análisis sintáctico en Windows: se compilará por primera vez en GitHub Actions.
- Pendiente de probar en un iPhone y en un teléfono Android con un Chromecast o Google TV en la misma red: descubrimiento, carga del HLS con segmentos TS y subtítulos WebVTT (y su sincronía), cambio de subtítulos, Sub/Dub, búsqueda, volumen, siguiente episodio, segundo plano y reanudación, y fin de sesión.
- iOS dentro de LiveContainer: falta comprobar que el aviso de red local aparece y que el framework dinámico del SDK carga en la app invitada.

## Versiones y releases

### Android TV: APK y actualizaciones

Cuando cambia `android/`, el workflow compila `AniBridgePlayer-TV.apk` y lo adjunta a la release. Las releases solo de Android no cambian el `latest` usado por iOS; Android busca en las releases estables la versión más reciente que incluya el APK. El botón **Actualizaciones** permite comprobar manualmente; además se comprueba sola al abrir la pantalla principal, como mucho cada 6 horas (la API de GitHub sin autenticar admite 60 consultas por hora). El usuario confirma la descarga y el instalador de Android pide confirmación para reemplazar la app. La app verifica el SHA-256 publicado por GitHub antes de entregar el APK al instalador del sistema (una sesión de `PackageInstaller`, así no aparece el selector «Abrir con» de otras apps que abren APKs). En el primer intento puede ser necesario permitir instalaciones desde esta app y volver a pulsar **Instalar**. Al volver de Ajustes la app comprueba el permiso y sigue con la instalación.

Los permisos especiales («Instalar apps desconocidas», «Mostrar sobre otras apps») son por perfil de Android, y Google TV suele tener un segundo perfil. `adb install` instala la app en todos los perfiles; en algunas TV (una TCL con Android 11) Ajustes lista entonces solo la copia del otro perfil, con un icono de maletín, y activarla no sirve. La app detecta esa copia y lo explica. Para evitarlo, instala por adb solo en el perfil principal: `adb install --user 0 AniBridgePlayer-TV.apk` (o quita la otra copia con `adb shell pm uninstall --user 10 com.personal.anksubbrd.tv`).

Para una release es obligatorio configurar estos secretos de Actions en el repositorio: `ANDROID_KEYSTORE_BASE64` (archivo del keystore codificado en base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` y `ANDROID_KEY_PASSWORD`. Conserva un respaldo seguro del keystore: las actualizaciones de Android solo pueden reemplazar una instalación firmada con la misma clave. Las compilaciones de prueba de pull requests o manuales usan una clave de depuración del runner y no son actualizaciones instalables sobre la release.

La app actualmente instalada con `assembleDebug` está firmada con el keystore de depuración de la máquina que la compiló. Para poder actualizarla sin desinstalarla, hay que configurar en GitHub esa misma clave y sus credenciales; la clave de depuración predeterminada suele estar en `%USERPROFILE%\.android\debug.keystore`, con alias `androiddebugkey` y contraseña `android`, pero verifica que sea realmente la utilizada. Si se usa una clave distinta, Android rechazará la actualización; reinstalar requiere desinstalar la app anterior y se perderán sus datos locales, por lo que conviene respaldar la identidad antes.

Para el keystore de depuración predeterminado de esta máquina, con GitHub CLI autenticado y desde PowerShell, se pueden configurar los cuatro secretos así (el contenido de la clave no se imprime):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\.android\debug.keystore")) | gh secret set ANDROID_KEYSTORE_BASE64 -R rsilva48/anksubbrd
'android' | gh secret set ANDROID_KEYSTORE_PASSWORD -R rsilva48/anksubbrd
'androiddebugkey' | gh secret set ANDROID_KEY_ALIAS -R rsilva48/anksubbrd
'android' | gh secret set ANDROID_KEY_PASSWORD -R rsilva48/anksubbrd
```

Estos valores solo sirven para el keystore de depuración predeterminado; si usaste otra clave, configura sus credenciales reales en su lugar. Compartir el keystore como secreto del repositorio permite a sus administradores y workflows autorizados usar esa clave, así que controla quién puede modificar esos workflows.

Los APK de release se compilan únicamente cuando la etiqueta coincide con `version.txt` y todos los secretos de firma están presentes; si faltan, el job falla y esa release no se publica. El flujo de actualización se debe probar en la TV tras publicar el primer APK firmado con la clave correcta.

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
| `android/` | Compila el APK firmado y lo adjunta a la release; si no hay cambios iOS, no cambia el **latest** usado por iOS. |
| Sólo `proxy/` | Prueba el bridge y publica una release sin IPA, que nunca se marca como latest. |
| Ninguno de los tres | No publica release. |

Así `https://github.com/rsilva48/anksubbrd/releases/latest/download/AirPlaySubtitlePlayer-unsigned.ipa` siempre apunta a un IPA y la app no ofrece actualizaciones que sólo tocaron el bridge. Las notas se agrupan en **App iOS**, **Android TV**, **Bridge** y **Repositorio**; las de una release de la app incluyen todo lo ocurrido desde el IPA anterior. **Actions → Build AniBridge Player → Run workflow** compila siempre, sin publicar release.

### Compilación iOS

La app requiere iOS/iPadOS 26 y usa los componentes nativos de Liquid Glass. El build de iOS corre en el runner `xcode-27` con **Xcode 27.1**, el primero con el SDK del iPhone Duo (plegable); el paso **Select Xcode** muestra la versión, el SDK y si la imagen trae el simulador del iPhone Duo. Para usar otra versión instalada en esa imagen (27.0 o 27.2), define la variable de repositorio `XCODE_VERSION` (por ejemplo `27.2`).

El IPA no está firmado: impórtalo en LiveContainer o fírmalo con tu herramienta de sideload (por ejemplo ByteLoader).

### Página de instalación con GitHub Pages

La página está en [`docs/index.html`](docs/index.html). Las notas de cada release de app incluyen un enlace HTTPS a la página con `?tag=vX.Y.Z`, además del enlace para descargar directamente la IPA. La página ofrece enlaces para instalar con LiveContainer y para descargar el archivo; sin parámetro `tag`, usa los assets de la última release de app marcada como `latest`.

Para publicarla:

1. Incluye `docs/index.html`, el workflow y los cambios de la app en el commit, y sube el commit y su etiqueta.
2. En GitHub, abre **Settings → Pages → Build and deployment** y elige **Source: GitHub Actions**. Publica [`.github/workflows/pages.yml`](.github/workflows/pages.yml), que se ejecuta cuando cambia `docs/` en `main` (o a mano desde **Actions → Publish install page → Run workflow**). Sustituye al workflow automático de GitHub, cuyas acciones todavía usan Node.js 20. La dirección es `https://rsilva48.github.io/anksubbrd/`.
3. En la nueva release de app, comprueba que se hayan publicado **ambos assets**, `AirPlaySubtitlePlayer-unsigned.ipa` y `manifest.plist`, y que el enlace de las notas lleve a la página con la etiqueta correcta. El workflow genera el manifiesto con la URL del IPA de esa versión; las releases antiguas no reciben el manifest automáticamente.
4. Prueba por separado el enlace desde la página y el botón de actualización de la app. El primero pasa por GitHub Pages; el segundo construye directamente el enlace para LiveContainer. Verifica el comportamiento con la app invitada abierta, el diálogo de reemplazo y la conservación de sus datos. Si no funciona, descarga el IPA desde la release e impórtalo manualmente.

## Límites técnicos

- Si una fuente no entrega HLS y VTT, no puede convertirse en subtítulos AirPlay.
- No se admiten DRM, paywalls ni mecanismos que impidan al receptor AirPlay recuperar el manifiesto.
- HTTP sólo funciona dentro de la red local; para un dominio público usa HTTPS.
- No se inicia sesión en el sitio de origen: el progreso compartido vive en tu bridge, protegido por token.
