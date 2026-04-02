# frozen_string_literal: true

# Copyright 2025 The Pangea Authors
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

require 'pangea-core'

# Core types and framework
require 'pangea/kubernetes/types'
require 'pangea/kubernetes/backend_registry'
require 'pangea/kubernetes/backends/base'
require 'pangea/kubernetes/backends/nixos_base'

# Architecture (user-facing API)
require 'pangea/kubernetes/architecture'

# Bare metal support
require 'pangea/kubernetes/bare_metal/cloud_init'
require 'pangea/kubernetes/bare_metal/cluster_reference'

# Elastic load balancer
require 'pangea/kubernetes/load_balancer'

# Network backends (CNI/mesh selection)
require 'pangea/kubernetes/network_backend_registry'
require 'pangea/kubernetes/network_backends/base'

# Compute backends are lazy-loaded by BackendRegistry — not required here.
# Network backends are lazy-loaded by NetworkBackendRegistry.
# Users only need the provider gem for backends they actually use.

require 'pangea-kubernetes/version'
