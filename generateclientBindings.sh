rm -rf src/app/client

docker run --rm -v "${PWD}:/local" --network host -u $(id -u ${USER}):$(id -g ${USER})  openapitools/openapi-generator-cli generate \
-i http://localhost:5042/api/openapi/v1/openapi.json \
-g typescript-angular \
-o /local/src/app/client