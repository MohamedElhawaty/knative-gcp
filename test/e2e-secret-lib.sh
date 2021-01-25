#!/usr/bin/env bash

# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source $(dirname "${BASH_SOURCE[0]}")/lib.sh

source $(dirname "${BASH_SOURCE[0]}")/../hack/lib.sh

source $(dirname "${BASH_SOURCE[0]}")/e2e-common.sh

function export_variable() {
  readonly E2E_TEST_NAMESPACE="default"

  readonly BROKER_GSA_SECRET_NAME="google-broker-key"

  if (( ! IS_PROW )); then
    readonly CONTROLLER_GSA_KEY_TEMP="$(mktemp)"
    readonly SOURCES_GSA_KEY_TEMP="$(mktemp)"
    readonly BROKER_GSA_KEY_TEMP="$(mktemp)"
  else
    readonly CONTROLLER_GSA_KEY_TEMP="${GOOGLE_APPLICATION_CREDENTIALS}"
    readonly SOURCES_GSA_KEY_TEMP="${GOOGLE_APPLICATION_CREDENTIALS}"
    readonly BROKER_GSA_KEY_TEMP="${GOOGLE_APPLICATION_CREDENTIALS}"
  fi
}

# Setup resources common to all eventing tests.
function test_setup() {
  export_variable || return 1
  controllers_gsa_setup || return 1
  sources_gsa_setup || return 1

  # Authentication check test for BrokerCell. It is used in integration test in secret mode.
  # We do not put it in the same place as other integration tests, because this test can not run in parallel with others,
  # as this test requires the entire BrokerCell to be non-functional.
  if [[ -v ENABLE_AUTH_CHECK_TEST && $ENABLE_AUTH_CHECK_TEST == "true" ]]; then
    test_authentication_check_for_brokercell "secret" || return 1
  fi

  broker_gsa_setup || return 1
  storage_setup || return 1
  scheduler_setup || return 1
  echo "Sleep 2 mins to wait for all resources to setup"
  sleep 120

  # Publish test images.
  publish_test_images
}

# Tear down tmp files which store the private key.
function test_teardown() {
  if (( ! IS_PROW )); then
    rm "${CONTROLLER_GSA_KEY_TEMP}"
    rm "${SOURCES_GSA_KEY_TEMP}"
    rm "${BROKER_GSA_KEY_TEMP}"
  fi
}

# Create resources required for the Controllers service account setup.
function controllers_gsa_setup() {
  # When not running on Prow we need to set up a service account for managing resources.
  if (( ! IS_PROW )); then
    echo "Set up the controllers service accoun"
    init_controller_gsa "${E2E_PROJECT_ID}" "${CONTROLLER_GSA_NON_PROW}"

    echo "Create the controllers service account secret"
    gcloud iam service-accounts keys create "${CONTROLLER_GSA_KEY_TEMP}" \
      --iam-account="${CONTROLLER_GSA_NON_PROW}"@"${E2E_PROJECT_ID}".iam.gserviceaccount.com
  fi

  echo "Create the controllers secret"
  kubectl -n "${CONTROL_PLANE_NAMESPACE}" create secret generic "${CONTROLLER_GSA_SECRET_NAME}" --from-file=key.json="${CONTROLLER_GSA_KEY_TEMP}"

  echo "Delete the controller pod in the namespace '${CONTROL_PLANE_NAMESPACE}' to refresh the created/patched secret"
  kubectl delete pod -n "${CONTROL_PLANE_NAMESPACE}" --selector role=controller

  wait_until_pods_running "${CONTROL_PLANE_NAMESPACE}" || return 1
}

# Create resources required for Sources authentication setup.
function sources_gsa_setup() {
  if (( ! IS_PROW )); then
    # When not running on Prow we need to set up a service account for sources.
    echo "Set up the Sources ServiceAccount"
    init_service_account_with_pubsub_editor "${E2E_PROJECT_ID}" "${SOURCES_GSA_NON_PROW}"
    enable_monitoring "${E2E_PROJECT_ID}" "${SOURCES_GSA_NON_PROW}"
    gcloud iam service-accounts keys create "${SOURCES_GSA_KEY_TEMP}" \
      --iam-account="${SOURCES_GSA_NON_PROW}"@"${E2E_PROJECT_ID}".iam.gserviceaccount.com
  else
    delete_topics_and_subscriptions
  fi

  # Create the sources secret
  echo "Create the sources secret"
  kubectl -n ${E2E_TEST_NAMESPACE} create secret generic "${SOURCES_GSA_SECRET_NAME}" --from-file=key.json="${SOURCES_GSA_KEY_TEMP}"
}

# Create resources required for Broker authentication setup.
function broker_gsa_setup() {
  echo "Authentication setup for GCP Broker"

  if (( ! IS_PROW )); then
    # When not running on Prow we need to set up a service account for broker.
    init_service_account_with_pubsub_editor "${E2E_PROJECT_ID}" "${BROKER_GSA_NON_PROW}"
    enable_monitoring "${E2E_PROJECT_ID}" "${BROKER_GSA_NON_PROW}"
    gcloud iam service-accounts keys create "${BROKER_GSA_KEY_TEMP}" \
      --iam-account="${BROKER_GSA_NON_PROW}"@"${E2E_PROJECT_ID}".iam.gserviceaccount.com
  fi

  # Create the broker secret
  echo "Create the broker secret"
  kubectl -n "${CONTROL_PLANE_NAMESPACE}" create secret generic "${BROKER_GSA_SECRET_NAME}" --from-file=key.json="${BROKER_GSA_KEY_TEMP}"

  warmup_broker_setup || true
}

function apply_invalid_auth() {
  kubectl -n "${CONTROL_PLANE_NAMESPACE}" create secret generic "${BROKER_GSA_SECRET_NAME}" --from-file=key.json=${CONFIG_INVALID_CREDENTIAL}
}

function delete_invalid_auth() {
  kubectl -n "${CONTROL_PLANE_NAMESPACE}" delete secret "${BROKER_GSA_SECRET_NAME}"
}
