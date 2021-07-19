import os
from rest_framework.exceptions import ValidationError

from db.tables import update_table, SUPPORTED_TABLE_UPDATE_ARGS


def user_directory_path(instance, filename):
    user_identifier = instance.user.username if instance.user else 'anonymous'
    # file will be uploaded to MEDIA_ROOT/user_<id>/<filename>
    return os.path.join(user_identifier, filename)


def update_sa_table(table, validated_data):
    errors = {
        arg: f'Updating {arg} for tables is not supported.'
        for arg in set(validated_data) - SUPPORTED_TABLE_UPDATE_ARGS
    }
    if errors:
        raise ValidationError(errors)
    update_table(table.name, table.schema.name, table.schema._sa_engine, validated_data)