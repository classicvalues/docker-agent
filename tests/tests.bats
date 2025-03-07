#!/usr/bin/env bats

load test_helpers
load 'test_helper/bats-support/load' # this is required by bats-assert!
load 'test_helper/bats-assert/load'

IMAGE=${IMAGE:-debian_jdk11}
SUT_IMAGE=$(get_sut_image)

ARCH=${ARCH:-x86_64}

@test "[${SUT_IMAGE}] checking image metadata" {
  local VOLUMES_MAP
  VOLUMES_MAP="$(docker inspect -f '{{.Config.Volumes}}' "${SUT_IMAGE}")"

  echo "${VOLUMES_MAP}" | grep '/home/jenkins/.jenkins'
  echo "${VOLUMES_MAP}" | grep '/home/jenkins/agent'
}

@test "[${SUT_IMAGE}] has utf-8 locale" {
  if [[ "${SUT_IMAGE}" == *"alpine"*  ]]; then
    run docker run --rm "${SUT_IMAGE}" /usr/glibc-compat/bin/locale charmap
  else
    run docker run --rm "${SUT_IMAGE}" locale charmap
  fi
  assert_equal "${output}" "UTF-8"
}

@test "[${SUT_IMAGE}] image has bash and java installed and in the PATH" {
  local cid
  cid="$(docker run -d -it -P "${SUT_IMAGE}" /bin/bash)"

  is_agent_container_running "${cid}"

  run docker exec "${cid}" sh -c "command -v bash"
  assert_success
  run docker exec "${cid}" bash --version
  assert_success
  run docker exec "${cid}" sh -c "command -v java"
  assert_success

  run docker exec "${cid}" sh -c "java -version"
  assert_success

  run docker exec "${cid}" sh -c "printenv | grep AGENT_WORKDIR"
  assert_equal "${output}" "AGENT_WORKDIR=/home/jenkins/agent"

  cleanup "$cid"
}

@test "[${SUT_IMAGE}] check user access to folders" {
  local cid
  cid="$(docker run -d -it -P "${SUT_IMAGE}" /bin/sh)"

  is_agent_container_running "${cid}"

  run docker exec "${cid}" touch /home/jenkins/a
  assert_success

  run docker exec "${cid}" touch /home/jenkins/.jenkins/a
  assert_success

  run docker exec "${cid}" touch /home/jenkins/agent/a
  assert_success

  cleanup "$cid"
}

@test "[${SUT_IMAGE}] use build args correctly" {
  cd "${BATS_TEST_DIRNAME}"/.. || false

  local TEST_VERSION="3.36"
	local TEST_USER="test-user"
	local TEST_GROUP="test-group"
	local TEST_UID=2000
	local TEST_GID=3000
	local TEST_AGENT_WORKDIR="/home/test-user/something"
  local sut_image="${SUT_IMAGE}-tests-${BATS_TEST_NUMBER}"

# false positive detecting platform
# shellcheck disable=SC2140
docker buildx bake \
  --set "${IMAGE}".args.VERSION="${TEST_VERSION}" \
  --set "${IMAGE}".args.user="${TEST_USER}" \
  --set "${IMAGE}".args.group="${TEST_GROUP}" \
  --set "${IMAGE}".args.uid="${TEST_UID}" \
  --set "${IMAGE}".args.gid="${TEST_GID}" \
  --set "${IMAGE}".args.AGENT_WORKDIR="${TEST_AGENT_WORKDIR}" \
  --set "${IMAGE}".platform="linux/${ARCH}" \
  --set "${IMAGE}".tags="${sut_image}" \
    --load `# Image should be loaded on the Docker engine`\
    "${IMAGE}"

  local cid
  cid="$(docker run -d -it -P "${sut_image}" /bin/sh)"

  is_agent_container_running "${cid}"

  run docker exec "${cid}" sh -c "java -cp /usr/share/jenkins/agent.jar hudson.remoting.jnlp.Main -version"
  assert_line --index 0 "${TEST_VERSION}"

  run docker exec "${cid}" sh -c "id -u -n ${TEST_USER}"
  assert_line --index 0 "${TEST_USER}"

  run docker exec "${cid}" sh -c "id -g -n ${TEST_USER}"
  assert_line --index 0 "${TEST_GROUP}"

  run docker exec "${cid}" sh -c "id -u ${TEST_USER}"
  assert_line --index 0 "${TEST_UID}"

  run docker exec "${cid}" sh -c "id -g ${TEST_USER}"
  assert_line --index 0 "${TEST_GID}"

  run docker exec "${cid}" sh -c "printenv | grep AGENT_WORKDIR"
  assert_line --index 0 "AGENT_WORKDIR=/home/${TEST_USER}/something"

  run docker exec "${cid}" sh -c 'stat -c "%U:%G" "${AGENT_WORKDIR}"'
  assert_line --index 0 "${TEST_USER}:${TEST_GROUP}"

  run docker exec "${cid}" touch /home/test-user/a
  assert_success

  run docker exec "${cid}" touch /home/test-user/.jenkins/a
  assert_success

  run docker exec "${cid}" touch /home/test-user/something/a
  assert_success

  cleanup "$cid"
}
