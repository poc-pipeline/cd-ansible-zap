DATABASES = {
    'default': {
        'ATOMIC_REQUESTS': True,
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'awx',
        'USER': 'awx',
        'PASSWORD': 'awxpass',
        'HOST': 'awx-postgres',
        'PORT': '5432',
    }
}

BROKER_URL = 'unix:///var/run/redis/redis.sock'
CHANNEL_LAYERS = {
    'default': {
        'BACKEND': 'channels_redis.core.RedisChannelLayer',
        'CONFIG': {
            'hosts': ['unix:///var/run/redis/redis.sock'],
            'capacity': 10000,
            'group_expiry': 157784760,
        },
    },
}

CLUSTER_HOST_ID = 'awx'
SECRET_KEY = 'awxsecretkey_for_poc_only'
RECEPTOR_SOCKET_FILE = '/var/run/receptor/receptor.sock'
ALLOWED_HOSTS = ['*']
CSRF_TRUSTED_ORIGINS = ['http://localhost:8043', 'http://127.0.0.1:8043']


# Execution Environment: job data shared between awx-task and EE containers
AWX_ISOLATION_BASE_PATH = '/tmp/awx-jobs'
# AWX_ISOLATION_SHOW_PATHS and DEFAULT_CONTAINER_RUN_OPTIONS are set
# dynamically by scripts/awx-setup.sh via the REST API
