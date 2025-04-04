# Copyright 2022 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Common code for implementing py_library rules."""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":attr_builders.bzl", "attrb")
load(
    ":attributes.bzl",
    "COMMON_ATTRS",
    "IMPORTS_ATTRS",
    "PY_SRCS_ATTRS",
    "PrecompileAttr",
    "REQUIRED_EXEC_GROUP_BUILDERS",
)
load(":builders.bzl", "builders")
load(":common.bzl", "collect_cc_info", "collect_imports", "collect_runfiles", "create_instrumented_files_info", "create_library_semantics_struct", "create_output_group_info", "create_py_info", "filter_to_py_srcs", "get_imports")
load(":flags.bzl", "AddSrcsToRunfilesFlag", "PrecompileFlag")
load(":precompile.bzl", "maybe_precompile")
load(":py_cc_link_params_info.bzl", "PyCcLinkParamsInfo")
load(":py_internal.bzl", "py_internal")
load(":rule_builders.bzl", "ruleb")
load(
    ":toolchain_types.bzl",
    "EXEC_TOOLS_TOOLCHAIN_TYPE",
    TOOLCHAIN_TYPE = "TARGET_TOOLCHAIN_TYPE",
)

_py_builtins = py_internal

LIBRARY_ATTRS = dicts.add(
    COMMON_ATTRS,
    PY_SRCS_ATTRS,
    IMPORTS_ATTRS,
    {
        "_add_srcs_to_runfiles_flag": lambda: attrb.Label(
            default = "//python/config_settings:add_srcs_to_runfiles",
        ),
    },
)

def _py_library_impl_with_semantics(ctx):
    return py_library_impl(
        ctx,
        semantics = create_library_semantics_struct(
            get_imports = get_imports,
            maybe_precompile = maybe_precompile,
            get_cc_info_for_library = collect_cc_info,
        ),
    )

def py_library_impl(ctx, *, semantics):
    """Abstract implementation of py_library rule.

    Args:
        ctx: The rule ctx
        semantics: A `LibrarySemantics` struct; see `create_library_semantics_struct`

    Returns:
        A list of modern providers to propagate.
    """
    direct_sources = filter_to_py_srcs(ctx.files.srcs)

    precompile_result = semantics.maybe_precompile(ctx, direct_sources)

    required_py_files = precompile_result.keep_srcs
    required_pyc_files = []
    implicit_pyc_files = []
    implicit_pyc_source_files = direct_sources

    precompile_attr = ctx.attr.precompile
    precompile_flag = ctx.attr._precompile_flag[BuildSettingInfo].value
    if (precompile_attr == PrecompileAttr.ENABLED or
        precompile_flag == PrecompileFlag.FORCE_ENABLED):
        required_pyc_files.extend(precompile_result.pyc_files)
    else:
        implicit_pyc_files.extend(precompile_result.pyc_files)

    default_outputs = builders.DepsetBuilder()
    default_outputs.add(precompile_result.keep_srcs)
    default_outputs.add(required_pyc_files)
    default_outputs = default_outputs.build()

    runfiles = builders.RunfilesBuilder()
    if AddSrcsToRunfilesFlag.is_enabled(ctx):
        runfiles.add(required_py_files)
    runfiles.add(collect_runfiles(ctx))
    runfiles = runfiles.build(ctx)

    cc_info = semantics.get_cc_info_for_library(ctx)
    py_info, deps_transitive_sources, builtins_py_info = create_py_info(
        ctx,
        original_sources = direct_sources,
        required_py_files = required_py_files,
        required_pyc_files = required_pyc_files,
        implicit_pyc_files = implicit_pyc_files,
        implicit_pyc_source_files = implicit_pyc_source_files,
        imports = collect_imports(ctx, semantics),
    )

    # TODO(b/253059598): Remove support for extra actions; https://github.com/bazelbuild/bazel/issues/16455
    listeners_enabled = _py_builtins.are_action_listeners_enabled(ctx)
    if listeners_enabled:
        _py_builtins.add_py_extra_pseudo_action(
            ctx = ctx,
            dependency_transitive_python_sources = deps_transitive_sources,
        )

    providers = [
        DefaultInfo(files = default_outputs, runfiles = runfiles),
        py_info,
        create_instrumented_files_info(ctx),
        PyCcLinkParamsInfo(cc_info = cc_info),
        create_output_group_info(py_info.transitive_sources, extra_groups = {}),
    ]
    if builtins_py_info:
        providers.append(builtins_py_info)
    return providers

_DEFAULT_PY_LIBRARY_DOC = """
A library of Python code that can be depended upon.

Default outputs:
* The input Python sources
* The precompiled artifacts from the sources.

NOTE: Precompilation affects which of the default outputs are included in the
resulting runfiles. See the precompile-related attributes and flags for
more information.

:::{versionchanged} 0.37.0
Source files are no longer added to the runfiles directly.
:::
"""

# NOTE: Exported publicaly
def create_py_library_rule_builder():
    """Create a rule builder for a py_library.

    :::{include} /_includes/volatile_api.md
    :::

    :::{versionadded} 1.3.0
    :::

    Returns:
        {type}`ruleb.Rule` with the necessary settings
        for creating a `py_library` rule.
    """
    builder = ruleb.Rule(
        implementation = _py_library_impl_with_semantics,
        doc = _DEFAULT_PY_LIBRARY_DOC,
        exec_groups = dict(REQUIRED_EXEC_GROUP_BUILDERS),
        attrs = LIBRARY_ATTRS,
        fragments = ["py"],
        toolchains = [
            ruleb.ToolchainType(TOOLCHAIN_TYPE, mandatory = False),
            ruleb.ToolchainType(EXEC_TOOLS_TOOLCHAIN_TYPE, mandatory = False),
        ],
    )
    return builder
