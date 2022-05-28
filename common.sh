#!/bin/bash
set -o errexit -o pipefail -o noclobber -o nounset -o posix

#TODO
# - if someone wants to override env variables defined in config he could define something like K8S_PROFILES_PATH_OVERRIDE. Search it here.

#args - https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
# saner programming env: these switches turn some bugs into errors
# initialize variables
progname=$(basename $0)
readonly progname
verbose=1
dryRun=${dryRun:-n}
command="usage"
#moved before set that will affect $@
readonly allArgs=$@
set -o errexit -o pipefail -o noclobber -o nounset
#set -o nounset [[ "${DEBUG?:-}" == 'true' ]] && set -o xtrace

red=$(echo -e '\x1b[31m\x0a')
green=$(echo -e '\x1b[32m\x0a')
reset=$(echo -e '\x1b[0;10m\x0a')
readonly red
readonly green
readonly reset
readonly identPrefix="   >"

function tern() {
  case $1 in '' | false | FALSE | null | NULL | 0 | 'n') echo "$3" ;; *) echo "$2" ;; esac
}

function execute() {
  echo "$ident${green}start>${reset} ${*/eval/}"
  "$@"
}

# $execute is initialized from dryRun
returnValue=""
function logAndExecute() {
  echo "$ident $(tern "$execute" "${green}start>${reset}" "${red}startDry>${reset}") ${*/eval/}"
  if [[ $execute == "y" ]]; then returnValue=$("$@"); else returnValue=""; fi
}

function title() {
  cat <<-HEREDOC
$ident ------------------------------
$ident ----- ${1:-Title}
HEREDOC
}

function idented() { printf "$1"'%.s' $(eval "echo {1.."$(($2))"}"); }

#The `$ident` variable can be used to ident any echo/print under the current function that was called with `call`
declare ident=""
function call() {
  ident="$ident$identPrefix"
  echo "$ident start $*"
  command -v "$1" 1>/dev/null || die "Invalid command $1."
  "$@"
  echo "$ident done $1"
  ident=${ident::-${#identPrefix}}
}

function finalCleanup {
  if [[ ! "${LEGACY_GOCD:-}" == "yes" ]] && [[ $(find . -name .gitsecret) ]]; then
    for d in $(find . -name .gitsecret); do
      RP=$(realpath $d)
      PDIR=$(dirname $RP)
      echo "========= Performing cleanup in $PDIR ============="
      for pd in $PDIR; do
        cd $pd
        for item in $(git secret list); do [[ -f $item ]] && rm $item || echo "Will not remove: $item - file does not exist"; done
        cd -
      done
    done
  fi
}
#trap finalCleanup EXIT

CURRENT_COMMAND="unknown command"
# keep track of the last executed command
trap '{ set +x; } 2>/dev/null; LAST_COMMAND=$CURRENT_COMMAND; CURRENT_COMMAND=$BASH_COMMAND' DEBUG
exitFunc() {
  RET=$?
  if [[ $RET -ne 0 ]]; then
    { set +x; } 2>/dev/null
    echo "$ident[FATAL] Command <${CURRENT_COMMAND}> failed with exit code $RET."
  fi
  finalCleanup
}
# echo an error message before exiting
trap 'exitFunc' EXIT

function die() {
  local message=$*
  [[ -z "$message" ]] && message="Died"
  echo "$ident${BASH_SOURCE[1]}: line ${BASH_LINENO[0]}: ${FUNCNAME[1]}: $message." >&2
  exit 1
}

function comment() {
  while read line; do echo "# $line"; done
}

function retry_on_failure_or_timeout() {

  local TIMEOUT=300
  local RETRIES=2
  local n=1

  # check if the command gives timeout
  timeout -k $TIMEOUT $((TIMEOUT - 5)) $*
  CODE=$?

  # if it's timeout, try for $RETRIES times
  while (($n < $RETRIES)) && [ $CODE = 124 ]; do
    echo "Command '$*' timed out. Attempt $n/$RETRIES.."
    ((n++))
    timeout -k $TIMEOUT $((TIMEOUT - 5)) $*
    CODE=$?
  done

  # after the retries the command works => return 0
  # if the code is not 0 or 124(timeout) => retry to run command
  if (($CODE == 124)); then
    echo "Command '$*' has timed out after $n attempts."
    return 124
  elif (($CODE == 0)); then
    echo "Command $@ executed successfully"
    return 0
  else
    while true; do
      eval "$*" && break || {
        if (($n < $RETRIES)); then
          echo "Command '$@' failed. Attempt $n/$RETRIES.."
          ((n++))
        else
          echo "Command has failed after $n attempts."
          return 1
        fi
      }
    done
  fi
}

function gitCleanup() {
  local -r _GIT_CLEAN_PARAMS=${GIT_CLEAN_PARAMS_OVERRIDE:-${_GIT_CLEAN_PARAMS:-"-ff -x -d .ssh target"}}
  local -r _GIT_CLEAN_ADDITIONAL_PARAMS=${GIT_CLEAN_ADDITIONAL_PARAMS_OVERRIDE:-${_GIT_CLEAN_ADDITIONAL_PARAMS:-""}}

  if (($verbose > 0)); then
    # print out all the parameters we read in
    cat <<-HEREDOC
    verbose=$verbose
    ---
    Performing cleanup using the following params for 'git clean':
    _GIT_CLEAN_PARAMS=${_GIT_CLEAN_PARAMS}
    _GIT_CLEAN_ADDITIONAL_PARAMS=${_GIT_CLEAN_ADDITIONAL_PARAMS}

    If you want to add or exclude more files or directories, please define _GIT_CLEAN_ADDITIONAL_PARAMS as the example below:
    _GIT_CLEAN_ADDITIONAL_PARAMS="delete_me.log -e target/keep_me.txt"

HEREDOC
  fi

  git clean $_GIT_CLEAN_PARAMS $_GIT_CLEAN_ADDITIONAL_PARAMS
  # Deprecated cleanup command. Can still be useful for decrypted files in the repo, regardless of the directory they're in. Can also be used in combination with the command above
  # for item in `git secret list`; do [[ -f $item ]] && rm $item || echo "Will not remove: $item - file does not exist"; done
}

#like gitUpdate but without repo
function gitUpdate2() {
  gitUpdate $@ "none"
}

function gitUpdate() {
  local -r MY_SCRIPTS_DIR=${1?Missing dir}
  local -r MY_SCRIPTS_GIT=${2?Missing git repository}
  if [[ "${gitUpdateDisabled:-}" != "true" ]]; then
    LEGACY_GOCD=${LEGACY_GOCD:-no}

    echo "$ident${green}Updating $MY_SCRIPTS_DIR (from $MY_SCRIPTS_GIT)${reset}"
    if [[ -d "$MY_SCRIPTS_DIR" ]]; then
      (
        cd "$MY_SCRIPTS_DIR"
        if [[ "$MY_SCRIPTS_GIT" != "none" ]]; then
          git remote set-url origin "$MY_SCRIPTS_GIT"
        fi
        git pull --ff-only --rebase --autostash
      ) || (
        echo "$ident${red}Could not pull in $MY_SCRIPTS_DIR ${reset}" &&
          ls -al "$MY_SCRIPTS_DIR"
      )
    else
      mkdir -p $MY_SCRIPTS_DIR/.. ||
        echo "$ident${red}Cannot mkdir $MY_SCRIPTS_DIR${reset}"
      (
        cd $MY_SCRIPTS_DIR/.. &&
          git clone "$MY_SCRIPTS_GIT" $(basename $MY_SCRIPTS_DIR) ||
          echo "$ident${red}Could not clone${reset}"
      )
    fi
    if [[ ! "${LEGACY_GOCD}" == "yes" ]] && [[ -d $MY_SCRIPTS_DIR/.gitsecret ]]; then
      cd $MY_SCRIPTS_DIR
      # Let it fail if latest version of encrypted files couldn't be decrypted
      git secret reveal -f
      for f in $(git secret list); do [[ -f $f ]] && chmod 600 $f || echo "${ident}Error. Does the file $f exist?"; done
    fi
    echo "$ident${green}done${reset}"
  else
    echo "$ident${green}disabled gitUpdate\($MY_SCRIPTS_DIR $MY_SCRIPTS_GIT\)${reset}"
  fi
}

function create_custom_tag() {

  # receive names of full and custom tag
  readonly DOCKER_IMAGE_TAG_CUSTOM=${DOCKER_IMAGE_TAG_CUSTOM?Missing custom tag}
  readonly DOCKER_IMAGE_TAG_FULL=${DOCKER_IMAGE_TAG_FULL?Missing full tag}

  readonly DOCKER_REGISTRY_USERNAME=${DOCKER_REGISTRY_USERNAME:-}
  readonly DOCKER_REGISTRY_PASSWORD=${DOCKER_REGISTRY_PASSWORD:-}
  readonly DOCKER_REGISTRY=${DOCKER_REGISTRY?Missing the docker registry.}
  readonly DOCKER_REPOSITORY=${DOCKER_REPOSITORY?Missing the docker repository.}
  readonly DOCKER_IMAGE_NAME=${DOCKER_IMAGE_NAME?Missing the image name.}

  readonly tag_full=$DOCKER_REGISTRY$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG_FULL
  readonly tag_custom=$DOCKER_REGISTRY$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG_CUSTOM

  # login and pull full_tag
  docker login $DOCKER_REGISTRY -u $DOCKER_REGISTRY_USERNAME -p $DOCKER_REGISTRY_PASSWORD
  docker pull $tag_full

  # tag and push full_tag with name of custom_tag
  docker tag $tag_full $tag_custom && retry_on_failure_or_timeout docker push $tag_custom || die "Cannot tag and push to $tag_custom"

}

function configBuild() {
  readonly GIT_ACCESS_TOKEN=${GIT_ACCESS_TOKEN?Missing git access token used by scripts.}
  readonly DOCKER_REGISTRY=${DOCKER_REGISTRY?Missing the docker registry. See selected part [registry.gitlab.com]/namek/backend}
  readonly DOCKER_REGISTRY_CHECK=${DOCKER_REGISTRY_CHECK_OVERRIDE:-${DOCKER_REGISTRY_CHECK:-Missing the docker registry. For example https://gitlab.com/namek/backend/container_registry or ${DOCKER_REGISTRY}/v2/_catalog}}

  readonly DOCKER_REGISTRY_USERNAME=${DOCKER_REGISTRY_USERNAME:-}
  readonly DOCKER_REGISTRY_PASSWORD=${DOCKER_REGISTRY_PASSWORD:-}
  readonly DOCKER_REPOSITORY=${DOCKER_REPOSITORY?Missing the docker repository. See selected part registry.gitlab.com[/namek]/namek-backend}
  readonly DOCKER_IMAGE_NAME=${DOCKER_IMAGE_NAME_OVERRIDE:-${DOCKER_IMAGE_NAME?Missing the image name. See selected part registry.gitlab.com/namek/[namek-backend]}}

  # readonly DOCKER_IMAGE_TAG_CUSTOM=${DOCKER_IMAGE_TAG_CUSTOM:-custom1}
  # echo "Using DOCKER_IMAGE_TAG_CUSTOM=$DOCKER_IMAGE_TAG_CUSTOM as custom image tag. You can override it if you need."
  echo "${green}done${reset}"

  readonly DOCKER_IMAGE_TAG_LATEST=${DOCKER_IMAGE_TAG_LATEST:-latest}
  readonly JAR_FILE=${JAR_FILE_OVERRIDE:-${JAR_FILE:-}}

  # PREPARE PROPERTIES
  # use some utilities to extract pom.xml version and timestamps
  readonly SCRIPTS_DIR=target/utility-scripts
  readonly SCRIPTS_GIT=https://$GIT_ACCESS_TOKEN@gitlab.com/namek-base/all/utility-scripts.git
  gitUpdate $SCRIPTS_DIR $SCRIPTS_GIT

  readonly BRANCH=${BRANCH_OVERRIDE:-${BRANCH:-master}}
  git checkout $BRANCH

  echo "Creating TAG using project version, git version and git timestamp"
  #readonly DOCKER_IMAGE_TAG_FULL=`target/utility-scripts/bin/version.sh $PWD`
  readonly DOCKER_IMAGE_TAG_FULL=$(projectVersion "$PWD")
  rm -rf image-tag.txt
  echo $DOCKER_IMAGE_TAG_FULL >image-tag.txt
  echo DOCKER_IMAGE_TAG_FULL=$DOCKER_IMAGE_TAG_FULL
  echo ${green}done${reset}
  readonly DOCKER_LOCAL_FAKE_REGISTRY=fake-inexistent-registry.namek-base.com
  readonly DOCKER_IMAGE=${DOCKER_LOCAL_FAKE_REGISTRY}$DOCKER_REPOSITORY/${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG_FULL}
  # readonly tag1=$DOCKER_REGISTRY$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG_CUSTOM
  readonly tag2=$DOCKER_REGISTRY$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG_FULL
  readonly tag3=$DOCKER_REGISTRY$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG_LATEST
  readonly DOCKERFILE=${DOCKERFILE_OVERRIDE:-${DOCKERFILE:-Dockerfile}}

  # END PREPARE PROPERTIES

  if (($verbose > 0)); then
    # print out all the parameters we read in
    cat <<-HEREDOC
    verbose=$verbose
    dryRun=$dryRun
    ---
	BRANCH=${BRANCH}
    DOCKER_REGISTRY=${DOCKER_REGISTRY}
    DOCKER_REGISTRY_CHECK=${DOCKER_REGISTRY_CHECK}
    DOCKER_REPOSITORY=${DOCKER_REPOSITORY}
    DOCKER_REGISTRY_USERNAME=${DOCKER_REGISTRY_USERNAME}
    DOCKER_REGISTRY_PASSWORD=<$(tern "$DOCKER_REGISTRY_PASSWORD" "secret is configured" "secret is NOT defined")>
    DOCKER_IMAGE_NAME=${DOCKER_IMAGE_NAME}
    DOCKER_IMAGE_TAG_FULL=${DOCKER_IMAGE_TAG_FULL}
    DOCKER_IMAGE_TAG_LATEST=${DOCKER_IMAGE_TAG_LATEST}
    DOCKERFILE=${DOCKERFILE}

    --- computed
    DOCKER_IMAGE=$DOCKER_IMAGE

    --- git
    GIT_ACCESS_TOKEN=<$(tern "$GIT_ACCESS_TOKEN" "secret is configured" "secret is NOT defined")>
    --- others
    SCRIPTS_GIT=$SCRIPTS_GIT
    JAR_FILE=$JAR_FILE
    ---
    execute=$execute
    DOCKER_BUILDKIT=1 docker build --network host --file=$DOCKERFILE --progress=plain --tag $DOCKER_IMAGE .
    docker login $DOCKER_REGISTRY -u $DOCKER_REGISTRY_USERNAME -p $DOCKER_REGISTRY_PASSWORD
    docker tag $DOCKER_IMAGE $tag2 && docker push $tag2
    docker tag $DOCKER_IMAGE $tag3 && docker push $tag3
    
    Notes
    - GOCD secure environment variables are displayed as *******.
HEREDOC
  fi
}

function _goss_tests() {
  readonly CMD=${CMD_OVERRIDE:-${CMD:-""}}

  if [[ -f goss.yaml ]]; then
    echo "Found 'goss.yaml' file. Checking if the required binaries are installed..."
    if which goss && which dgoss; then
      goss -v
      echo "Running tests on the newly built docker image: $DOCKER_IMAGE"
      echo "==> dgoss run $DOCKER_IMAGE $CMD"
      dgoss run $DOCKER_IMAGE $CMD
    else
      echo "WARNING: Couldn't find the required binaries. Please make sure both 'goss' and 'dgoss' are installed and executable"
    fi
  else
    echo "No 'goss.yaml' file present. Skipping tests"
  fi
}

function configDeploy() {
  readonly GIT_ACCESS_TOKEN=${GIT_ACCESS_TOKEN?Missing git access token used by scripts. If using GOCD you can define it as a secret in the gocd environment named [${GO_ENVIRONMENT_NAME:-<no environment>}]}
  readonly K8S_DOCKER_REGISTRY=${K8S_DOCKER_REGISTRY?Missing the docker registry. See selected part [registry.gitlab.com]/namek/namek-backend}
  readonly K8S_DOCKER_REGISTRY_CHECK=${K8S_DOCKER_REGISTRY_CHECK:-Missing the docker registry. For example https://gitlab.com/namek/namek-backend/container_registry or ${K8S_DOCKER_REGISTRY}/v2/_catalog}
  readonly K8S_DOCKER_REGISTRY_USERNAME=${K8S_DOCKER_REGISTRY_USERNAME:-}
  readonly K8S_DOCKER_REGISTRY_PASSWORD=${K8S_DOCKER_REGISTRY_PASSWORD:-}
  readonly DOCKER_REPOSITORY=${DOCKER_REPOSITORY?Missing the docker registry. See selected part registry.gitlab.com[/namek]/namek-backend}
  readonly DOCKER_IMAGE_NAME=${DOCKER_IMAGE_NAME_OVERRIDE:-${DOCKER_IMAGE_NAME?Missing the docker registry. See selected part registry.gitlab.com/namek/[namek-backend]}}

  # PREPARE PROPERTIES
  readonly DOCKER_TAG=${DOCKER_TAG_OVERRIDE:-${DOCKER_TAG:-$(cat image-tag.txt)}}
  readonly DOCKER_IMAGE=${DOCKER_IMAGE_NAME}:${DOCKER_TAG}
  readonly DOCKER_IMAGE_MANIFEST=http://$K8S_DOCKER_REGISTRY/v2$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME/manifests/${DOCKER_TAG}
  readonly K8S_DEPLOYMENT_PROFILE_BASE=${K8S_DEPLOYMENT_PROFILE_BASE_OVERRIDE:-${K8S_DEPLOYMENT_PROFILE_BASE?Missing kubernetes deployment profile. Should be one under https://$GIT_ACCESS_TOKEN@gitlab.com/namek-base/all/kubernetes/kubernetes-autodeploy-profiles/}}
  readonly K8S_DEPLOYMENT_PROFILE_GIT=https://$GIT_ACCESS_TOKEN@gitlab.com/namek-base/all/kubernetes/kubernetes-autodeploy-profiles/$K8S_DEPLOYMENT_PROFILE_BASE.profile.git
  readonly K8S_SCRIPTS_GIT=https://$GIT_ACCESS_TOKEN@gitlab.com/namek-base/all/kubernetes/kubernetes-autodeploy.git
  LEGACY_GOCD=${LEGACY_GOCD:-no}
  [[ "${LEGACY_GOCD}" == "yes" ]] && export K8S_PROFILES_PATH=/shared-projects/kubernetes-autodeploy/profiles
  [[ "${LEGACY_GOCD}" == "yes" ]] && export K8S_SCRIPTS_PATH=/shared-projects/kubernetes-autodeploy
  #readonly K8S_PROFILES_PATH=`realpath -m ${K8S_PROFILES_PATH_OVERRIDE:-${K8S_PROFILES_PATH:-target/kubernetes-autodeploy/profiles}}`
  readonly K8S_PROFILES_PATH=${K8S_PROFILES_PATH_OVERRIDE:-${K8S_PROFILES_PATH:-target/kubernetes-autodeploy/profiles}}
  readonly K8S_SCRIPTS_PATH=${K8S_SCRIPTS_PATH_OVERRIDE:-${K8S_SCRIPTS_PATH:-target/kubernetes-autodeploy}}
  readonly K8S_DEPLOYMENT_PROFILES_LIST=https://$GIT_ACCESS_TOKEN@gitlab.com/namek-base/all/kubernetes/kubernetes-autodeploy-profiles/$K8S_DEPLOYMENT_PROFILE_BASE.profile/-/tree/master/bin
  readonly -a K8S_APP_DEPLOY_SCRIPT=${K8S_APP_DEPLOY_SCRIPT_OVERRIDE:-${K8S_APP_DEPLOY_SCRIPT?Missing deploy script name. See $K8S_DEPLOYMENT_PROFILES_LIST}}

  # END PREPARE PROPERTIES

  if (($verbose > 0)); then
    # print out all the parameters we read in
    cat <<-HEREDOC
    verbose=$verbose
    dryRun=$dryRun
    ---
    K8S_DOCKER_REGISTRY=$K8S_DOCKER_REGISTRY
    K8S_DOCKER_REGISTRY_CHECK=$K8S_DOCKER_REGISTRY_CHECK
    DOCKER_REPOSITORY=$DOCKER_REPOSITORY
    K8S_DOCKER_REGISTRY_USERNAME=$K8S_DOCKER_REGISTRY_USERNAME
    K8S_DOCKER_REGISTRY_PASSWORD=<$(tern "$K8S_DOCKER_REGISTRY_PASSWORD" "secret is configured" "secret is NOT defined")>
    DOCKER_IMAGE_NAME=$DOCKER_IMAGE_NAME
    DOCKER_TAG=$DOCKER_TAG

    --- computed
    DOCKER_IMAGE=$DOCKER_IMAGE
    DOCKER_IMAGE_MANIFEST=${DOCKER_IMAGE_MANIFEST}

    --- git
    GIT_ACCESS_TOKEN=<$(tern "$GIT_ACCESS_TOKEN" "secret is configured" "secret is NOT defined")>
    --- ansible profile at
    K8S_PROFILES_PATH=$K8S_PROFILES_PATH
    K8S_DEPLOYMENT_PROFILE_BASE=$K8S_DEPLOYMENT_PROFILE_BASE
    K8S_DEPLOYMENT_PROFILE_GIT=$K8S_DEPLOYMENT_PROFILE_GIT
    K8S_DEPLOYMENT_PROFILES_LIST=$K8S_DEPLOYMENT_PROFILES_LIST

    K8S_APP_DEPLOY_SCRIPT=$K8S_APP_DEPLOY_SCRIPT
    --- build
    K8S_SCRIPTS_GIT=$K8S_SCRIPTS_GIT
    
    Notes
    - GOCD secure environment variables are displayed as *******.
HEREDOC
  fi

  function prepareProfilesAndUtilities() {
    (
      local -r SCRIPTS_DIR=$(realpath -m $K8S_PROFILES_PATH/../)
      local -r SCRIPTS_GIT=$K8S_SCRIPTS_GIT
      gitUpdate $SCRIPTS_DIR $SCRIPTS_GIT
    )

    (
      local -r SCRIPTS_DIR=$(realpath -m $K8S_PROFILES_PATH/$K8S_DEPLOYMENT_PROFILE_BASE.profile)
      local -r SCRIPTS_GIT=$K8S_DEPLOYMENT_PROFILE_GIT
      gitUpdate $SCRIPTS_DIR $SCRIPTS_GIT
    )
  }
}

function projectVersion() {
  #copied and slightly changed from https://gitlab.com/namek-base/all/utility-scripts/-/blob/master/bin/version.sh
  (
    #cd $(readlink -f ${0%/*})

    OUTPUT_VERSION='0.0.1-snapshot'

    WORKING_DIR="$1"

    ## Validations
    if [[ ! -d "$WORKING_DIR" ]]; then
      echo "[ERROR] Invalid working dir <$WORKING_DIR>" >&2
      exit 1
    fi

    pushd $WORKING_DIR >/dev/null
    GIT_TAG="$(git log --oneline | wc -l)-$(git rev-parse --short HEAD)-$(git log -1 --date=format:%Y_%m_%d-%H_%M_%S --pretty=format:%cd)"
    popd >/dev/null

    ## Project detection
    # Maven project?
    PROJECT_FILE="$WORKING_DIR/pom.xml"
    if [[ -f "$PROJECT_FILE" ]]; then
      #if python 2.5
      OUTPUT_VERSION=$(python3 -c "import xml.etree.ElementTree as ET; print(ET.parse(open('pom.xml')).getroot().find( '{http://maven.apache.org/POM/4.0.0}version').text)")
      #sudo apt-get install libxml2-utils --yes
      #. ../lib/xml.sh
      #OUTPUT_VERSION=`xmlpath \"$PROJECT_FILE\" '/project/version'`
      if [[ $? -ne 0 ]]; then
        echo "[ERROR] Command failed" >&2
        exit 2
      fi
    else
      # Node.js project?
      PROJECT_FILE="$WORKING_DIR/package.json"
      if [[ -f "$PROJECT_FILE" ]]; then
        #https://stackoverflow.com/questions/1955505/parsing-json-with-unix-tools
        OUTPUT_VERSION=$(cat $PROJECT_FILE | python3 -c "import sys, json; print(json.load(sys.stdin)['version'])")
        #OUTPUT_VERSION=`jq -r '.version' \"$PROJECT_FILE\"`
        if [[ $? -ne 0 ]]; then
          echo "[ERROR] Command failed" >&2
          exit 2
        fi
      fi
    fi
    echo "$OUTPUT_VERSION-$GIT_TAG"
  )
}

function dockerDeploy() {
  configDeploy
  local -r _K8S_DEPLOYMENT_PROFILE_PATH=$K8S_PROFILES_PATH/$K8S_DEPLOYMENT_PROFILE_BASE.profile

  if [[ $execute == "y" ]]; then
    prepareProfilesAndUtilities
    set -x
    for i in ${!K8S_APP_DEPLOY_SCRIPT[@]}; do
      profile="${K8S_APP_DEPLOY_SCRIPT[i]}"
      $_K8S_DEPLOYMENT_PROFILE_PATH/bin/$profile -- -e custom_deployment_tag=$DOCKER_TAG -e registry=$K8S_DOCKER_REGISTRY$DOCKER_REPOSITORY
    done
    if [[ ! "${LEGACY_GOCD}" == "yes" ]] && [[ -d $_K8S_DEPLOYMENT_PROFILE_PATH/.gitsecret ]]; then
      cd $_K8S_DEPLOYMENT_PROFILE_PATH
      gitCleanup
    fi
    set +x
  fi
  cat <<HEREDOC
  Released image from ${K8S_DOCKER_REGISTRY_CHECK}:
  - manifest of a the tag/reference
    curl ${DOCKER_IMAGE_MANIFEST}

  ${green}done${reset}
HEREDOC
}

function dockerBuildTagPush() {
  local -r executeMaven=${1:-}
  _base_dir=$(readlink -f ${BASH_SOURCE[0]} | grep -o '.*/')
  configBuild
  if [[ $execute == "y" ]]; then
    if [[ $executeMaven == "executeMaven" ]]; then
      echo Executing mvn build. TODO: Should be replaced by a multistage Dockerfile like in gothaer-app project
      mvn -version
      java -version
      javac -version
      mvn install -DskipTests -e
    fi
    ls -al target
    echo Executing docker build, tag and push
    set -x
    DOCKER_BUILDKIT=1 docker build --network host --file=$DOCKERFILE --progress=plain --tag $DOCKER_IMAGE --build-arg JAR_FILE=$JAR_FILE . 2>&1 | tee output.log
    set +e
    grep -wEf $_base_dir/fail-msg-list.txt output.log
    if [[ $? -eq 0 ]]; then
      echo "======= BUILD FAILED ======="
      exit 7
    fi
    set +x -e

    _goss_tests
    if [[ $DOCKER_REGISTRY_USERNAME ]]; then
      docker login $DOCKER_REGISTRY -u $DOCKER_REGISTRY_USERNAME -p $DOCKER_REGISTRY_PASSWORD
      #TODO to see how to use GIT_ACCESS_TOKEN docker login $DOCKER_REGISTRY GIT_ACCESS_TOKEN ???
    fi
    #TODO script should fail if docker tag fails. Now it continues
    docker tag $DOCKER_IMAGE $tag2 && retry_on_failure_or_timeout docker push $tag2 || die "Cannot tag and push to $tag2"
    docker tag $DOCKER_IMAGE $tag3 && retry_on_failure_or_timeout docker push $tag3 || die "Cannot tag and push to $tag3"

    if [[ ! "${LEGACY_GOCD}" == "yes" ]] && [[ -d .gitsecret ]]; then
      gitCleanup
    fi
  fi

  cat <<HEREDOC
  See released images at ${DOCKER_REGISTRY_CHECK}:
  - list repositories
    curl http://$DOCKER_REGISTRY/v2/_catalog
  - list image tags in repository
    curl http://$DOCKER_REGISTRY/v2$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME/tags/list
  - manifest of a tag/reference
    curl http://$DOCKER_REGISTRY/v2$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME/manifests/latest
  - http://$DOCKER_REGISTRY/v2$DOCKER_REPOSITORY/$DOCKER_IMAGE_NAME/manifests/<reference>

  ${green}done${reset}
HEREDOC
}

function mvnTest() {
  local -r target=${target:-test}

  ## Variables
  LEGACY_GOCD=${LEGACY_GOCD:-no}
  [[ "${LEGACY_GOCD}" == "yes" ]] && export HOST_WORKDIR=/home/shared/gocd/$(hostname | awk -F'[-.]' '{print $2"-"$3}')
  HOST_WORKDIR=${HOST_WORKDIR:-/mnt/revo-gocd-agent-workdir}
  TEST_CONTAINER_WORKDIR=${TEST_CONTAINER_WORKDIR:-/work}
  PROJECT_DIR_NAME=${PROJECT_DIR_NAME:-"${PWD##*/}"}
  TEST_CONTAINER_PROJECT_DIR=${TEST_CONTAINER_PROJECT_DIR:-$TEST_CONTAINER_WORKDIR/pipelines/$PROJECT_DIR_NAME}
  TEST_CONTAINER_IMAGE=${TEST_CONTAINER_IMAGE:-"maven:3.8.1-adoptopenjdk-15"}
  MAVEN_CONFIG_DIR=${MAVEN_CONFIG_DIR:-$TEST_CONTAINER_WORKDIR/.m2}
  MAVEN_SUREFIRE_TAGS=${MAVEN_SUREFIRE_TAGS:-(!slow&!integration)}
  MAVEN_SUREFIRE_XMX=${MAVEN_SUREFIRE_XMX:-2040}
  SHOULD_FAIL=${SHOULD_FAIL:-"--fail-at-end"}
  logAndExecute docker run -u 1000 --rm \
    -e MAVEN_CONFIG=$MAVEN_CONFIG_DIR \
    -v $HOST_WORKDIR:$TEST_CONTAINER_WORKDIR \
    $TEST_CONTAINER_IMAGE \
    bash -c "
      cd $TEST_CONTAINER_PROJECT_DIR
      mvn -Duser.home=$TEST_CONTAINER_WORKDIR ${target} ${SHOULD_FAIL} -e \
-DMY_APP_LOG_LEVEL=WARN \
-Dgroups=\"${MAVEN_SUREFIRE_TAGS}\" \
-DargLine=\"@{argLine} -Xmx${MAVEN_SUREFIRE_XMX}m\" "
}
function mvnTestNoFail() {
  SHOULD_FAIL="--fail-never -Dmaven.test.failure.ignore=true"
  target="test jacoco:report"
  call mvnTest
}
function mvnCompile() {
  ## Variables
  LEGACY_GOCD=${LEGACY_GOCD:-no}
  [[ "${LEGACY_GOCD}" == "yes" ]] && export HOST_WORKDIR=/home/shared/gocd/$(hostname | awk -F'[-.]' '{print $2"-"$3}')
  HOST_WORKDIR=${HOST_WORKDIR:-/mnt/revo-gocd-agent-workdir}
  TEST_CONTAINER_WORKDIR=${TEST_CONTAINER_WORKDIR:-/work}
  PROJECT_DIR_NAME=${PROJECT_DIR_NAME:-"${PWD##*/}"}
  TEST_CONTAINER_PROJECT_DIR=${TEST_CONTAINER_PROJECT_DIR:-$TEST_CONTAINER_WORKDIR/pipelines/$PROJECT_DIR_NAME}
  TEST_CONTAINER_IMAGE=${TEST_CONTAINER_IMAGE:-"maven:3.8.1-adoptopenjdk-15"}
  MAVEN_CONFIG_DIR=${MAVEN_CONFIG_DIR:-$TEST_CONTAINER_WORKDIR/.m2}

  logAndExecute docker run -u 1000 --rm \
    -e MAVEN_CONFIG=$MAVEN_CONFIG_DIR \
    -v $HOST_WORKDIR:$TEST_CONTAINER_WORKDIR \
    $TEST_CONTAINER_IMAGE \
    bash -c \
    "cd $TEST_CONTAINER_PROJECT_DIR
      mvn -Duser.home=$TEST_CONTAINER_WORKDIR compile -DskipTests=true"
}

function sonarScan() {
  # Maven project?
  [[ -f "$PWD/pom.xml" ]] && call mvnTestNoFail
  # [[ -f "$PWD/pom.xml" ]] && mvnCompile

  ## Variables
  LEGACY_GOCD=${LEGACY_GOCD:-no}
  [[ "${LEGACY_GOCD}" == "yes" ]] && export HOST_WORKDIR="/home/shared/gocd/$(hostname | awk -F'[-.]' '{print $2"-"$3}')"
  HOST_WORKDIR=${HOST_WORKDIR:-/mnt/revo-gocd-agent-workdir}
  PROJECT_DIR_NAME=${PROJECT_DIR_NAME:-"${PWD##*/}"}
  HOST_PROJECT_DIR_PATH=${HOST_PROJECT_DIR_PATH:-$HOST_WORKDIR/pipelines/$PROJECT_DIR_NAME}
  SONAR_LOGIN_TOKEN=${SONAR_LOGIN_TOKEN}

  #logAndExecute docker build -t mybuild/sonar-scanner-cli --file SonarDockerfile .
  #mybuild/sonar-scanner-cli:latest
  logAndExecute docker run \
    -u 1000 --rm \
    -e SONAR_LOGIN="$SONAR_LOGIN_TOKEN" \
    -v "$HOST_PROJECT_DIR_PATH:/usr/src" \
    sonarsource/sonar-scanner-cli:4.7.0 \
    -Dproject.settings=.sonar.properties
}

function k8sScale() {
  REPLICAS=${REPLICAS?Please provide the number of replicas you want to scale to}
  NS=${NS:-default}
  APP_NAME=${APP_NAME:-""}
  LABEL_KEY=${LABEL_KEY:-app}
  LABEL_VALUE=${LABEL_VALUE:-$APP_NAME}

  POD_NAME=$(kubectl -n $NS get pods -l $LABEL_KEY=$LABEL_VALUE -o name | tail -n1)

  OWNER_NAME_LVL1=$(kubectl -n $NS get $POD_NAME -o jsonpath="{.metadata.ownerReferences[].name}")
  OWNER_KIND_LVL1=$(kubectl -n $NS get $POD_NAME -o jsonpath="{.metadata.ownerReferences[].kind}")

  if [[ "${OWNER_KIND_LVL1}" == "ReplicaSet" ]]; then
    OWNER_NAME_LVL2=$(kubectl -n $NS get $OWNER_KIND_LVL1/$OWNER_NAME_LVL1 -o jsonpath="{.metadata.ownerReferences[].name}")
    OWNER_KIND_LVL2=$(kubectl -n $NS get $OWNER_KIND_LVL1/$OWNER_NAME_LVL1 -o jsonpath="{.metadata.ownerReferences[].kind}")
    kubectl -n $NS scale $OWNER_KIND_LVL2/$OWNER_NAME_LVL2 --replicas=$REPLICAS
  else
    kubectl -n $NS scale $OWNER_KIND_LVL1/$OWNER_NAME_LVL1 --replicas=$REPLICAS
  fi

  if (($verbose > 0)); then
    # print out all the parameters we read in
    cat <<-HEREDOC
    verbose=$verbose
    ---
	  Used the following variables:
    REPLICAS=${REPLICAS}
    NS=${NS}
    APP_NAME=${APP_NAME}
    LABEL_KEY=${LABEL_KEY}
    LABEL_VALUE=${LABEL_VALUE}
    POD_NAME=${POD_NAME}
    OWNER_NAME_LVL1=${OWNER_NAME_LVL1}
    OWNER_KIND_LVL1=${OWNER_KIND_LVL1}
    OWNER_NAME_LVL2=${OWNER_NAME_LVL2}
    OWNER_KIND_LVL2=${OWNER_KIND_LVL2}
HEREDOC
  fi
}

function postgresBackup() {
  readonly RELEASE=${RELEASE_OVERRIDE:-${RELEASE?Missing release tag for backup}}
  readonly PG_DUMP_BINARY=${PG_DUMP_BINARY:-pg_dump}
  readonly PG_HOST=${PG_HOST_OVERRIDE:-${PG_HOST:-localhost}}
  readonly PG_PORT=${PG_PORT_OVERRIDE:-${PG_PORT:-5432}}
  readonly PG_DB_NAME=${PG_DB_NAME_OVERRIDE:-${PG_DB_NAME:-postgres}}
  readonly PG_SCHEMA=${PG_SCHEMA_OVERRIDE:-${PG_SCHEMA:-}}
  readonly PG_USERNAME=${PG_USERNAME?Missing username. Please set PG_USERNAME=<user_name>}
  readonly PG_FORMAT=${PG_FORMAT:-plain}
  readonly PG_ENCODING=${PG_ENCODING:-UTF-8}
  readonly PG_COMPRESSION_LEVEL=${PG_COMPRESSION_LEVEL:-9}
  readonly PG_VERBOSE=$(tern $verbose "--verbose" "")
  readonly PG_OUTPUT_FILE="$PG_OUTPUT_FILE_PATH/$RELEASE$PG_SCHEMA-postgres-export-$(date '+%Y-%m-%d_%H-%M-%S')"
  readonly PG_INSTALL_PACKAGE="postgresql-client"

  if (($verbose > 0)); then
    # print out all the parameters we read in
    cat <<-HEREDOC
    verbose=$verbose
    ---
    RELEASE=${RELEASE}
    PG_DUMP_BINARY=${PG_DUMP_BINARY}
    PG_HOST=${PG_HOST}
    PG_PORT=${PG_PORT}
    PG_DB_NAME=${PG_DB_NAME}
    PG_SCHEMA=${PG_SCHEMA}
    PG_USERNAME=${PG_USERNAME}
    PGPASSWORD=$(tern "$PGPASSWORD" "PGPASSWORD is configured" "PGPASSWORD was NOT provided")
    PG_FORMAT=${PG_FORMAT}
    PG_ENCODING=${PG_ENCODING}
    PG_VERBOSE=$PG_VERBOSE
    PG_OUTPUT_FILE=$PG_OUTPUT_FILE
HEREDOC
  fi

  $PG_DUMP_BINARY -V || echo "$PG_INSTALL_PACKAGE is not installed. Pleased install it and try again"

  PGPASSWORD=$PGPASSWORD $PG_DUMP_BINARY --host=$PG_HOST --port=$PG_PORT --dbname=$PG_DB_NAME --format=$PG_FORMAT --encoding=$PG_ENCODING $PG_VERBOSE --compress=$PG_COMPRESSION_LEVEL --schema=$PG_SCHEMA --username=$PG_USERNAME >"$PG_OUTPUT_FILE" &&
    zip -r -9 $PG_OUTPUT_FILE.zip $PG_OUTPUT_FILE && rm $PG_OUTPUT_FILE
}

function postgresRestore() {
  readonly PG_HOST=${PG_HOST_OVERRIDE:-${PG_HOST:-localhost}}
  readonly PG_PORT=${PG_PORT_OVERRIDE:-${PG_PORT:-5432}}
  readonly PG_DB_NAME=${PG_DB_NAME_OVERRIDE:-${PG_DB_NAME:-postgres}}
  readonly PG_USERNAME=${PG_USERNAME:-postgres}
  readonly PG_ECHO_ERRORS=${PG_ECHO_ERRORS:---echo-errors}
  readonly PG_IMPORT_FILE=${PG_IMPORT_FILE?Please provide the file to import from}
  readonly PG_INSTALL_PACKAGE="postgresql-client"

  if (($verbose > 0)); then
    # print out all the parameters we read in
    cat <<-HEREDOC
    verbose=$verbose
    ---
    PG_HOST=${PG_HOST}
    PG_PORT=${PG_PORT}
    PG_DB_NAME=${PG_DB_NAME}
    PG_USERNAME=${PG_USERNAME}
    PGPASSWORD=$(tern "$PGPASSWORD" "PGPASSWORD is configured" "PGPASSWORD was NOT provided")
    PG_ECHO_ERRORS=${PG_ECHO_ERRORS}
    PG_IMPORT_FILE=$PG_IMPORT_FILE
HEREDOC
  fi

  psql -V || echo "$PG_INSTALL_PACKAGE is not installed. Pleased install it and try again"

  PGPASSWORD=$PGPASSWORD psql --host=$PG_HOST --port=$PG_PORT --dbname=$PG_DB_NAME --username=$PG_USERNAME $PG_ECHO_ERRORS --file=$PG_IMPORT_FILE
}

function applyConfig() {
  local -r K8S_PROFILES_PATH=${K8S_PROFILES_PATH_OVERRIDE:-${K8S_PROFILES_PATH:-/shared-projects/kubernetes-autodeploy/profiles}}
  local -r K8S_DEPLOYMENT_PROFILE_BASE=${K8S_DEPLOYMENT_PROFILE_BASE_OVERRIDE:-${K8S_DEPLOYMENT_PROFILE_BASE?Missing kubernetes deployment profile. Should be one under https://gitlab.com/namek-base/all/kubernetes/kubernetes-autodeploy-profiles/}}
  local -r SCRIPTS_DIR=${K8S_PROFILES_PATH}/${K8S_DEPLOYMENT_PROFILE_BASE}.profile/bin
  #local -r APPLY_CONFIG_SCRIPT_ABS_PATH=${SCRIPTS_DIR}/${APPLY_CONFIG_SCRIPT}

  if (($verbose > 0)); then
    # print out all the parameters we read in
    cat <<-HEREDOC
    verbose=$verbose
    ---
    K8S_PROFILES_PATH=${K8S_PROFILES_PATH}
    K8S_DEPLOYMENT_PROFILE_BASE=${K8S_DEPLOYMENT_PROFILE_BASE}
    SCRIPTS_DIR=${SCRIPTS_DIR}
HEREDOC
  fi

  gitUpdate2 $SCRIPTS_DIR

  # Let it fail if git pull was not successful
  #echo "Attempting to pull latest code..."
  #git pull --ff-only --rebase --autostash

  cd $SCRIPTS_DIR
  echo "Listing current directory files in [$SCRIPTS_DIR]"
  ls -alh

  echo ${green}"executing $SCRIPTS_DIR/$APPLY_CONFIG_SCRIPT"${reset}
  ./$APPLY_CONFIG_SCRIPT
}

function applyConfig1() {
  #readonly K8S_PROFILES_PATH=${K8S_PROFILES_PATH_OVERRIDE:-${K8S_PROFILES_PATH:-/shared-projects/kubernetes-autodeploy/profiles}}
  #readonly K8S_DEPLOYMENT_PROFILE_BASE=${2:-${K8S_DEPLOYMENT_PROFILE_BASE_OVERRIDE:-${K8S_DEPLOYMENT_PROFILE_BASE?Missing parameter2|K8S_DEPLOYMENT_PROFILE_BASE_OVERRIDE|K8S_DEPLOYMENT_PROFILE_BASE - kubernetes deployment #profile. Should be one under https://gitlab.com/namek-base/all/kubernetes/kubernetes-autodeploy-profiles/}}}
  #readonly SCRIPTS_DIR=${3:-${K8S_PROFILES_PATH}/${K8S_DEPLOYMENT_PROFILE_BASE}.profile}
  #local -r MY_SCRIPTS_DIR=${1?Missing dir with yml files. For example vars/project or vars/project/app-project-backend-ingress.ym}
  #readonly APPLY_CONFIG_SCRIPT_ABS_PATH=${SCRIPTS_DIR}/${MY_SCRIPTS_DIR}
  readonly CONFIGS_DIR=${1?Mising yml configs dir cloned from https://gitlab.com/namek/namek-kube-profiles/ }

  # could retrieve entire profile and decrypt
  #echo buildpath=[$buildPath]
  #echo profile=[$K8S_DEPLOYMENT_PROFILE_BASE]
  #gitUpdate $buildPath-profile-$K8S_DEPLOYMENT_PROFILE_BASE/ https://${GIT_ACCESS_TOKEN:-}@gitlab.com/namek/namek-kube-profiles/$K8S_DEPLOYMENT_PROFILE_BASE.profile
  gitUpdate $buildPath-kubernetes-autodeploy/ https://gitlab.com/namek/namek-kube-autodeploy.git

  gitUpdate2 $SCRIPTS_DIR
  (
    cd $CONFIGS_DIR
    # Let it fail if git pull was not successful
    #echo "Attempting to pull latest code in [$CONFIGS_DIR] ..."
    #git pull --ff-only --rebase --autostash

    echo "Listing current directory files:"
    ls -alh
  )

  #bin references ../../../generic-kubernetes.sh
  $buildPath-kubernetes-autodeploy/generic-ansible2.sh $CONFIGS_DIR
}

function applyConfig2() {
  readonly CONFIGS_DIR=${1?Mising yml configs dir cloned from https://gitlab.com/namek/namek-kube-profiles/ }

  gitUpdate $buildPath-kubernetes-autodeploy/ https://gitlab.com/namek/namek-kube-autodeploy.git
  gitUpdate2 $CONFIGS_DIR

  echo "Listing current directory files:"
  ls -alh $CONFIGS_DIR

  #bin references ../../../generic-kubernetes.sh
  $buildPath-kubernetes-autodeploy/generic-ansible2.sh $CONFIGS_DIR
}

function mavenAndDockerBuildTagPush() {
  dockerBuildTagPush executeMaven
}

function dockerDeployNotify() {
  logAndExecute curl -X POST https://chat.namek.com/hooks/Zyuz3Bpwa98PpoSxF/NzwLWXDHfAzfxea9CXhCbytzm6odTEmEq4ABvgoiPj74E2pb \
    -H 'Content-Type: application/json' \
    --data @- <<EOF
{
  "alias":"GoCD deployment",
  "avatar":"https://hub.kubeapps.com/api/chartsvc/v1/assets/gocd/gocd/logo",
  "text":"Green-backend will be deployed",
  "attachments":[{
    "title":"",
    "title_link":"",
    "text":"",
    "image_url":"",
    "color":""
  }]
}
EOF
  echo "$ident $returnValue"
}

# Join arguments with delimiter
# @Params
# $1: The delimiter string
# ${@:2}: The arguments to join
# @Output
# >&1: The arguments separated by the delimiter string
function array_joinArgs() {
  (($#)) || return 1 # At least delimiter required
  local -- delim="$1" str IFS=
  shift
  str="${*/#/$delim}"       # Expand arguments with prefixed delimiter (Empty IFS)
  printf "${str:${#delim}}" # Echo without first delimiter
}

function array_join() {
  local delim="$1"
  eval local ids=\(\${$2[@]}\)
  if ((${#ids[@]} > 0)); then
    printf ${ids[0]}
    if ((${#ids[@]} > 1)); then
      printf "$delim%s" ${ids[@]:1}
    fi
  fi
}

function array_mkstring() {
  local delimStart="$1"
  local delimMiddle="$2"
  local delimEnd="$3"
  eval local ids=\(\${$4[@]}\)
  if ((${#ids[@]} > 0)); then
    # shellcheck disable=SC2059
    printf "$delimStart"
    # shellcheck disable=SC2059
    printf "${ids[0]}"
    if ((${#ids[@]} > 1)); then
      printf "$delimMiddle%s" "${ids[@]:1}"
    fi
    # shellcheck disable=SC2059
    printf "$delimEnd"
  fi
}
function array_print() {
  #printf "\n===%s" ${commands[@]}
  array_join "," "$1"
}

function releaseGreenAsBlue() {
  echo "${ident} releaseGreenAsBlue"
  local -r srcName=$1
  local -r dstName=$2
  local -r gitopsDir=target/build-gitops
  gitUpdate $gitopsDir/ https://${credentials}github.com/raisercostin/namek-gitops.git

  local -r srcFile=target/build-gitops/$srcName
  local -r dstFile=target/build-gitops/$dstName
  local -r srcVersion=$(execute cat $srcFile | grep registry.gitlab.com/namek/all | sed -r "s/^[^:]*:[^:]*:([^ ]*)( .*)?$/\1/")
  local -r dstVersion=$(execute cat $dstFile | grep registry.gitlab.com/namek/all | sed -r "s/^[^:]*:[^:]*:([^ ]*)( .*)?$/\1/")
  echo "$ident Found version [$srcVersion] in $srcFile"
  echo "$ident Found version [$dstVersion] in $dstFile"
  #some changes might still be local
  #if [[ "${srcVersion}" != "${dstVersion}" ]]; then
  echo "$ident Upgrade to [$srcVersion] found in $srcFile"
  sed -i "s|$dstVersion|$srcVersion|g" $dstFile
  (
    cd $gitopsDir
    echo "git commit -am \"Upgrade to [$srcVersion] found in $srcFile. Old version [$dstVersion]\""
    git commit -am "Upgrade to [$srcVersion] found in $srcFile. Old version [$dstVersion]" || echo "$ident Nothing to commit"
    git push
  )
  #else
  #  echo "$ident No Change"
  #fi
}
function releaseGreenAsBlueBackend() {
  call releaseGreenAsBlue env-blue/project1/statefulset.project1-blue-backend.yaml env-green/project1/statefulset.project1-backend.yaml
  call dockerDeployNotify
}
function releaseGreenAsBlueOfficeApp() {
  releaseGreenAsBlue env-blue/project1/deployment.project1-blue-office-app.yaml env-green/project1/deployment.project1-office-app.yaml
}
function releaseGreenAsBlueUserApp() {
  releaseGreenAsBlue env-blue/project1/deployment.project1-blue-user-app.yaml env-green/project1/deployment.project1-user-app.yaml
}

#Trying to configure autocomplete for build.sh
#complete -W 'dockerBuildTagPush dockerBuildTagPush mvnTest sonarScan dockerDeploy k8sScale postgresBackup postgresRestore applyConfig applyConfig2 dockerDeployNotify'  build.sh
#complete
function printContext() {
  cat <<HEREDOC
Overview
-----------
Script to
- Build a docker image
- Push it to a registry
- Deploy to kubernetes via ansible
- Perform postgres export & import

Context
-----------
Called: '$progname $allArgs'
HOSTNAME: $(hostname)
PWD: $(pwd)
LS:
$(ls -al)
-----------
HEREDOC
}

function readConfiguredVariables() {
  if test -f "config.sh"; then
    echo "Reading configured environment variables from './config.sh'"
    # shellcheck source=/dev/null
    source config.sh
  fi
}

#simple escape - https://stackoverflow.com/questions/255898/how-to-iterate-over-arguments-in-a-bash-script
function escape() {
  echo "$1"
}

function usageCommand2() {
  cat <<HEREDOC
  
  Called: '$progname $allArgs'

  Usage: $progname [command] [arguments]

  Commands:
    $progname dockerBuildTagPush
        package - build, package, tag and push with docker (for multistage docker, should work with maven, node, etc...)

    $progname mavenAndDockerBuildTagPush
        package - build, package, tag and push with maven and docker - for projects without docker multistage that need maven to be preinstalled

    $progname create_custom_tag
        tag - create a custom tag from an existing one

    $progname mvnTest
        test - run maven tests on project code

    $progname sonarScan
        scan - run sonar-scan in a docker container to analyse the project

    $progname dockerDeploy
        deploy  - deploy docker image with scripts

    $progname k8sScale
        scale  - scale kuberntes objects to the specified number of replicas

    $progname postgresBackup
        backup  - performs a postgres backup dumped in a file using 'pg_dump' command

    $progname postgresRestore
        restore - performs a postgres restore using 'psql' command

    $progname applyConfig
        apply - runs a specified configuration script

  Arguments:
    --dry-run            do a dry run, dont change any files
    -v, --verbose        increase the verbosity of the bash script (0-no verbosity)
    -h, --help           show this help message and exit

HEREDOC
}

function usageCommand() {
  # shellcheck disable=SC2207
  declare -a detectedCommands=($(declare -F | grep -oE '([^ ]+)Command$' | sed 's/\(.*\)Command$/\1/'))

  declare -l ident=""
  declare -l delim="\n$ident - "
  cat <<HEREDOC1

Called: '$progname $allArgs'

Syntax: $progname <command>

<command>:
  Detected - functions ending with \`Command\`$(array_mkstring "$delim" "$delim" "" detectedCommands)

  Main:$(array_mkstring "$delim" "$delim" "" mainCommands)

<flags>:
 - $(array_mkstring "$delim" "$delim" "" mainProperties)

Samples:
  SONAR_LOGIN_TOKEN=none gitUpdateDisabled=false dryRun=true ./build.sh sonarScan

HEREDOC1
  #  Custom:$(array_mkstring "$delim" "$delim" "" customCommands)
}

function commandExists() {
  type "$1" &>/dev/null
}

function commandRun() {
  local commandHere=${1?$(usageCommand)}
  if commandExists "${commandHere}"; then
    call "$command" "${rest[@]}"
  elif commandExists "${commandHere}Command"; then
    call "${command}Command" "${rest[@]}"
  else
    echo "Command $command not found"
  fi
}

readConfiguredVariables
#printSamples
#printContext

verbose='false'
aflag=''
bflag=''
files=''
while getopts 'abf:v' flag; do
  case "${flag}" in
  a) aflag='true' ;;
  b) bflag='true' ;;
  f) files="${OPTARG}" ;;
  v) verbose='true' ;;
  *) error "Unexpected option ${flag}" ;;
  esac
done

declare -a all
declare -a commands=()
declare -a flags
#this is how you preconfigure defaults
#declare -a flags=("--verbose")

for arg in $allArgs; do
  #echo "analyzing $arg"
  case "$arg" in
  -*)
    all+=("$(escape \"$arg\")")
    flags+=("$(escape \"$arg\")")
    ;;
  *)
    all+=("$(escape \"$arg\")")
    commands+=("$arg")
    ;;
  esac
done

if ((${#commands[@]} > 0)); then
  command="${commands[0]}"
  rest=("${commands[@]:1}" "${flags[@]}")
fi

if [[ ${debug:-n} == "y" ]]; then
  cat <<HEREDOC
Debug Command
-------
all=${all[@]}
commands=${commands[@]}
flags=${flags[@]}

command=$command
rest=${rest[@]}
-------
HEREDOC
fi

#while [ "$#" -gt 0 ]; do
#  case "$1" in
#    #-a|--all) all="y"; shift;;
#    #-p|--push) push="y"; shift;;
#    #-n) name="$2"; shift 2;;
#    #-p) pidfile="$2"; shift 2;;
#    #-l) logfile="$2"; shift 2;;
#
#    #--name=*) name="${1#*=}"; shift 1;;
#    #--pidfile=*) pidfile="${1#*=}"; shift 1;;
#    #--logfile=*) logfile="${1#*=}"; shift 1;;
#    #--name|--pidfile|--logfile) echo "$1 requires an argument" >&2; exit 1;;
#
#    # standard options
#    -h|--help) command="usageCommand"; shift 1; ;;
#    --dry-run ) dryRun="y"; shift ;;
#    -v | --verbose ) verbose=$((verbose + 1)); shift ;;
#
#    -*) echo "unknown option: $1"; shift 1;; # >&2; exit 1;;
#    *) echo "unknown param: $1"; shift 1;;
#  esac
#done

readonly execute=$(tern $dryRun "n" "y")
readonly mainCommands=(
  dockerBuildTagPush
  'dockerBuildTagPush executeMaven'
  create_custom_tag
  mavenAndDockerBuildTagPush
  mvnTest
  sonarScan
  dockerDeploy
  k8sScale
  postgresBackup
  postgresRestore
  applyConfig
  applyConfig2
  dockerDeployNotify
  releaseGreenAsBlue-yaml1-yaml2
  releaseGreenAsBlueBackend
  releaseGreenAsBlueOfficeApp
  releaseGreenAsBluePlayerApp
)
readonly mainProperties=(
  'verbose:0|1'
  'dryRun:true|false'
  'gitUpdateDisabled:true|false'
)
if [ -z "${bootstrapVersion+xxx}" ]; then commandRun "$command"; fi
