import http
import os
from flask import Flask, Response, jsonify, request
from azure.identity import DefaultAzureCredential
from pymongo import MongoClient
from pymongo.auth_oidc import OIDCCallback, OIDCCallbackContext, OIDCCallbackResult
from dotenv import load_dotenv
from bson import ObjectId
from bson.json_util import dumps
import json
from contextlib import contextmanager

load_dotenv()

endpoint = os.environ.get('SETTINGS__ENDPOINT')
database_name = os.environ.get('SETTINGS__DATABASENAME', 'cosmicworks')
collection_name = os.environ.get('SETTINGS__COLLECTIONNAME', 'products')


class AzureIdentityTokenCallback(OIDCCallback):
    def __init__(self, credential):
        self.credential = credential

    def fetch(self, context: OIDCCallbackContext) -> OIDCCallbackResult:
        token = self.credential.get_token(
            "https://ossrdbms-aad.database.windows.net/.default").token
        return OIDCCallbackResult(access_token=token)


class MongoJSONEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, ObjectId):
            return str(obj)
        return super().default(obj)


app = Flask(__name__)
app.json_encoder = MongoJSONEncoder


def get_mongo_client():
    """Create and return a MongoDB client."""
    try:
        credential = DefaultAzureCredential()
        authProperties = {
            "OIDC_CALLBACK": AzureIdentityTokenCallback(credential)}
        client = MongoClient(
            f"mongodb+srv://{endpoint}/",
            connectTimeoutMS=120000,
            tls=True,
            retryWrites=True,
            authMechanism="MONGODB-OIDC",
            authMechanismProperties=authProperties
        )
        return client
    except Exception as e:
        print(f"Error creating MongoDB client: {e}")
        return None


@contextmanager
def get_collection():
    """
    Context manager that provides access to the MongoDB collection.
    Handles client creation and cleanup automatically.

    Usage:
        with get_collection() as (collection, error_response):
            if error_response:
                return error_response
            # Use collection here

    Returns:
        Tuple containing (collection, error_response)
        If error_response is not None, it indicates a connection error occurred
    """
    client = None
    try:
        client = get_mongo_client()
        if not client:
            error = ("Could not connect to MongoDB",
                     http.HTTPStatus.INTERNAL_SERVER_ERROR)
            yield None, error
            return

        db = client[database_name]
        collection = db[collection_name]
        yield collection, None
    except Exception as e:
        error = (str(e), http.HTTPStatus.INTERNAL_SERVER_ERROR)
        yield None, error
    finally:
        if client:
            client.close()


@app.route('/', methods=['GET'])
def get_all():
    with get_collection() as (collection, error):
        if error:
            return error

        try:
            documents = list(collection.find())
            return Response(dumps(documents), mimetype='application/json'), http.HTTPStatus.OK
        except Exception as e:
            return str(e), http.HTTPStatus.INTERNAL_SERVER_ERROR


@app.route('/<id>', methods=['GET'])
def get_by_id(id):
    with get_collection() as (collection, error):
        if error:
            return error

        try:
            # Use the ID directly as a string
            document = collection.find_one({'id': id})
            if document:
                return jsonify(document), 200
            else:
                return "Document not found", http.HTTPStatus.NOT_FOUND
        except Exception as e:
            return str(e), http.HTTPStatus.INTERNAL_SERVER_ERROR


@app.route('/category/<name>', methods=['GET'])
def get_by_category(name):
    with get_collection() as (collection, error):
        if error:
            return error

        try:
            # Query documents filtered by category
            documents = list(collection.find({'category': name}))

            if documents:
                return jsonify(documents), http.HTTPStatus.OK
            else:
                # Return empty array instead of 404 to follow REST conventions for empty results
                return jsonify([]), http.HTTPStatus.OK
        except Exception as e:
            return str(e), http.HTTPStatus.INTERNAL_SERVER_ERROR


@app.route('/', methods=['POST'])
def create_document():
    with get_collection() as (collection, error):
        if error:
            return error

        try:
            # Get document data from request
            data = request.get_json()
            if not data or 'name' not in data:
                return "Missing payload", http.HTTPStatus.BAD_REQUEST

            filter = {
                "id": data["id"],
            }
            payload = {
                "$set": data
            }
            collection.update_one(filter, payload, upsert=True)

            return '', http.HTTPStatus.CREATED
        except Exception as e:
            return str(e), http.HTTPStatus.INTERNAL_SERVER_ERROR


@app.route('/<id>', methods=['DELETE'])
def delete_document(id):
    with get_collection() as (collection, error):
        if error:
            return error

        try:
            # Delete document with string ID
            result = collection.delete_one({'id': id})

            if result.deleted_count > 0:
                return "Document deleted", http.HTTPStatus.NO_CONTENT
            else:
                return "Document not found", http.HTTPStatus.NOT_FOUND
        except Exception as e:
            return str(e), http.HTTPStatus.INTERNAL_SERVER_ERROR


@app.route('/status/', methods=['GET'])
def status():
    client = None
    try:
        client = get_mongo_client()
        if not client:
            return "Could not connect to MongoDB", http.HTTPStatus.INTERNAL_SERVER_ERROR

        ping_result = client.admin.command('ping')

        status = {"host": endpoint,
                  "isHealthy": ping_result.get('ok', 0) == 1}

        return jsonify(status), http.HTTPStatus.OK
    except Exception as e:
        return str(e), http.HTTPStatus.INTERNAL_SERVER_ERROR
    finally:
        # Close the MongoDB connection
        if client:
            client.close()
