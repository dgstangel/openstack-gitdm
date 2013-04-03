#!/bin/bash

# provide debugging output when desired
function DEBUG() {
    [ "$_DEBUG" == "on" ] && echo "DEBUG: $1"
}

# enable/disable debugging output
_DEBUG="on"

GITBASE=~/git/openstack
RELEASE=grizzly
BASEDIR=$(pwd)
CONFIGDIR=$(pwd)/openstack-config
TEMPDIR=${TEMPDIR:-$(mktemp -d $(pwd)/dmtmp-XXXXXX)}
GITLOGARGS="--no-merges --numstat -M --find-copies-harder"

UPDATE_GIT=${UPDATE_GIT:-y}
GIT_STATS=${GIT_STATS:-y}
LP_STATS=${LP_STATS:-y}
QUERY_LP=${QUERY_LP:-y}
GERRIT_STATS=${GERRIT_STATS:-y}
REMOVE_TEMPDIR=${REMOVE_TEMPDIR:-y}

if [ ! -d .venv ]; then
    echo "Creating a virtualenv"
    ./tools/install_venv.sh
fi

# current list of CI / infrastructure projects - everything else will be considered "core"
# see https://wiki.openstack.org/wiki/Projects for an authoritative list
CI_PROJECTS='config|zuul|jenkins|jeepyb|devstack|git|gerrit|meetbot|openstack|nose|tempest'

# generate a list of the CORE projects...
CORE_PROJECTS=`grep -v '^#' ${CONFIGDIR}/${RELEASE} | grep -Ev "^(${CI_PROJECTS})" |
    while read project x; do
        echo ${project}
    done`
DEBUG "Got CORE_PROJECTS = '${CORE_PROJECTS}'"

# generate a list of the INFRASTRUCTURE projects...
INFRA_PROJECTS=`grep -v '^#' ${CONFIGDIR}/${RELEASE} | grep -E "^(${CI_PROJECTS})" |
    while read project x; do
        echo ${project}
    done`
DEBUG "Got INFRA_PROJECTS = '${INFRA_PROJECTS}'"


if [ "$UPDATE_GIT" = "y" ]; then
    echo "Updating projects from git"
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project x; do
          DEBUG "Updating ${project}"
          cd ${GITBASE}/${project}
          echo -n "${project}: "
          # gerrit is currently using upstream version 2.4.2, so only look at that branch
          if [ "$project" = "gerrit" ] ; then
             git checkout openstack/2.4.2
          else
              git fetch origin 2>/dev/null
          fi
        done
fi

if [ "$GIT_STATS" = "y" ] ; then
    echo "Generating git commit logs"
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project revisions excludes x; do
            DEBUG "Generating git commit log for ${project}"
            cd ${GITBASE}/${project}
            git log ${GITLOGARGS} ${revisions} > "${TEMPDIR}/${project}-commits.log"

            # kludge to exclude large sets of commits:
            # If a file called ${project}.exclude exists in the config dir, then treat
            # its contents as a list of commits to exclude from the statistics. 
            # This is done for projects whose commit logs include a lot of automated commits
            # (such as all of the Jenkins commits to nova) that need to be excluded, and which
            # otherwise would overwhelm the 'awk' command
            if [ -r ${CONFIGDIR}/${project}.exclude ]; then
                DEBUG "Excluding large set of commits for ${project}..."
                for A in `cat ${CONFIGDIR}/${project}.exclude`; do
                    DEBUG "Excluding $A"
                    awk "/^commit /{ok=1} /^commit ${A}/{ok=0} {if(ok) {print}}" \
                        < "${TEMPDIR}/${project}-commits.log" > "${TEMPDIR}/${project}-commits.log.$A"
                    mv "${TEMPDIR}/${project}-commits.log.$A" "${TEMPDIR}/${project}-commits.log"
                done
            elif [ -n "$excludes" ]; then
                # otherwise if there is a small list of excludes in the config file
                # then process with awk (this was the original exclude mechanism)
                awk "/^commit /{ok=1} /^commit ${excludes}/{ok=0} {if(ok) {print}}" \
                    < "${TEMPDIR}/${project}-commits.log" > "${TEMPDIR}/${project}-commits.log.new"
                mv "${TEMPDIR}/${project}-commits.log.new" "${TEMPDIR}/${project}-commits.log"
            fi
        done

    echo "Generating git statistics"
    DEBUG "Generating git statistics for each sub-project"
    cd ${BASEDIR}
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project x; do
            DEBUG "Generating git stats for ${project}"
            python gitdm -l 20 -n < "${TEMPDIR}/${project}-commits.log" > "${TEMPDIR}/${project}-git-stats.txt"
        done

    DEBUG "Generating aggregate git stats for CORE projects"
    for project in ${CORE_PROJECTS}; do
        cat "${TEMPDIR}/${project}-commits.log" >> "${TEMPDIR}/core-git-commits.log"
    done
    python gitdm -l 20 -n < "${TEMPDIR}/core-git-commits.log" > "${TEMPDIR}/core-git-stats.txt"

    DEBUG "Generating aggregate git stats for INFRASTRUCTURE projects"
    for project in ${INFRA_PROJECTS}; do
        cat "${TEMPDIR}/${project}-commits.log" >> "${TEMPDIR}/infra-git-commits.log"
    done
    python gitdm -l 20 -n < "${TEMPDIR}/infra-git-commits.log" > "${TEMPDIR}/infra-git-stats.txt"

    DEBUG "Generating aggregate git stats for ALL of openstack"
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project x; do
            cat "${TEMPDIR}/${project}-commits.log" >> "${TEMPDIR}/git-commits.log"
        done
    python gitdm -l 20 -n < "${TEMPDIR}/git-commits.log" > "${TEMPDIR}/git-stats.txt"
fi


if [ "$LP_STATS" = "y" ] ; then
    echo "Generating a list of bugs"
    cd ${BASEDIR}
    # get a list of all the launchpad projects we want to examine.
    # Exclude comments and all of the infrastructure/ci projects
    LP_PROJECTS=`grep -v '^#' ${CONFIGDIR}/${RELEASE} | grep -Ev "^(${CI_PROJECTS})" |
        while read project x; do
            echo ${project}
        done`

    DEBUG "Got LP_PROJECTS = '${LP_PROJECTS}'"

    for project in ${LP_PROJECTS}; do

        DEBUG "Retrieving bug list for project ${project}"
        ./tools/with_venv.sh python launchpad/buglist.py ${project} ${RELEASE} > "${TEMPDIR}/${project}-bugs.log"
        while read id person date x; do
            emails=$(awk "/^$person / {print \$2}" ${CONFIGDIR}/launchpad-ids.txt)
            echo $id $person $date $emails
        done < "${TEMPDIR}/${project}-bugs.log" > "${TEMPDIR}/${project}-bugs.log.new"
        mv "${TEMPDIR}/${project}-bugs.log.new" "${TEMPDIR}/${project}-bugs.log"

    done

    # handle the special case of openstack-ci which includes all of the openstack 
    # infrastructure / ci bugs, because openstack-ci uses different Launchpad
    # attributes to organize its bugs
    project=openstack-ci
    DEBUG "Retriving bug list for project ${project}"
    ./tools/with_venv.sh python launchpad/openstack-ci-buglist.py ${RELEASE} > "${TEMPDIR}/${project}-bugs.log"
    while read id person date x; do
        emails=$(awk "/^$person / {print \$2}" ${CONFIGDIR}/launchpad-ids.txt)
        echo $id $person $date $emails
    done < "${TEMPDIR}/${project}-bugs.log" > "${TEMPDIR}/${project}-bugs.log.new"
    mv "${TEMPDIR}/${project}-bugs.log.new" "${TEMPDIR}/${project}-bugs.log"

    echo "Generating launchpad statistics"
    cd ${BASEDIR}
    for project in $LP_PROJECTS; do
        grep -v '<unknown>' "${TEMPDIR}/${project}-bugs.log" |
            python lpdm -l 20 > "${TEMPDIR}/${project}-lp-stats.txt"
    done

    DEBUG "Generating aggregate launchpad stats for CORE projects"
    for project in ${CORE_PROJECTS}; do
        grep -v '<unknown>' "${TEMPDIR}/${project}-bugs.log" >> "${TEMPDIR}/core-lp-bugs.log"
    done
    grep -v '<unknown>' "${TEMPDIR}/core-lp-bugs.log" | 
        python lpdm -l 20 < "${TEMPDIR}/core-lp-bugs.log" > "${TEMPDIR}/core-lp-stats.txt"

    DEBUG "Generating aggregate launchpad stats for ALL of openstack"
    for project in $LP_PROJECTS; do
        grep -v '<unknown>' "${TEMPDIR}/${project}-bugs.log" >> "${TEMPDIR}/lp-bugs.log"
    done

    grep -v '<unknown>' "${TEMPDIR}/lp-bugs.log" |
        python lpdm -l 20 > "${TEMPDIR}/lp-stats.txt"

fi


if [ "$GERRIT_STATS" = "y" ] ; then
    echo "Generating a list of Change-Ids"
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project revisions x; do
            cd "${GITBASE}/${project}"
            git log ${revisions} |
                awk '/^    Change-Id: / { print $2 }' |
                split -l 100 -d - "${TEMPDIR}/${project}-${RELEASE}-change-ids-"
        done

    cd ${TEMPDIR}
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project x; do
            > ${project}-${RELEASE}-reviews.json
            for f in ${project}-${RELEASE}-change-ids-??; do
                echo "Querying gerrit: ${f}"
                ssh -p 29418 review.openstack.org \
                    gerrit query --all-approvals --format=json \
                    $(awk -v ORS=' OR '  '{print}' $f | sed 's/ OR $//') \
                    < /dev/null >> "${project}-${RELEASE}-reviews.json"
            done
        done

    echo "Generating a list of commit IDs"
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project revisions x; do
            cd "${GITBASE}/${project}"
            git log --pretty=format:%H $revisions > \
                "${TEMPDIR}/${project}-${RELEASE}-commit-ids.txt"
        done

    echo "Parsing the gerrit queries"
    cd ${BASEDIR}
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project x; do
            python gerrit/parse-reviews.py \
                "${TEMPDIR}/${project}-${RELEASE}-commit-ids.txt" \
                "${CONFIGDIR}/launchpad-ids.txt" \
                < "${TEMPDIR}/${project}-${RELEASE}-reviews.json"  \
                > "${TEMPDIR}/${project}-${RELEASE}-reviewers.txt"
        done

    echo "Generating gerrit statistics"
    cd ${BASEDIR}
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project x; do
            python gerritdm -l 20 \
                < "${TEMPDIR}/${project}-${RELEASE}-reviewers.txt" \
                > "${TEMPDIR}/${project}-gerrit-stats.txt"
        done

    DEBUG "Generating aggregate gerrit stats for CORE projects"
    > "${TEMPDIR}/core-gerrit-reviewers.txt"
    for project in ${CORE_PROJECTS}; do
        cat "${TEMPDIR}/${project}-${RELEASE}-reviewers.txt" >> "${TEMPDIR}/core-gerrit-reviewers.txt"
    done
    python gerritdm -l 20 < "${TEMPDIR}/core-gerrit-reviewers.txt" > "${TEMPDIR}/core-gerrit-stats.txt"


    DEBUG "Generating aggregate gerrit stats for INFRASTRUCTURE projects"
    > "${TEMPDIR}/infra-gerrit-reviewers.txt"
    for project in ${INFRA_PROJECTS}; do
    cat "${TEMPDIR}/${project}-${RELEASE}-reviewers.txt" >> "${TEMPDIR}/infra-gerrit-reviewers.txt"
done
    python gerritdm -l 20 < "${TEMPDIR}/infra-gerrit-reviewers.txt" > "${TEMPDIR}/infra-gerrit-stats.txt"

    DEBUG "Generating aggregate gerrit stats for ALL of openstack"
    > "${TEMPDIR}/gerrit-reviewers.txt"
    grep -v '^#' ${CONFIGDIR}/${RELEASE} |
        while read project x; do
            cat "${TEMPDIR}/${project}-${RELEASE}-reviewers.txt" >> "${TEMPDIR}/gerrit-reviewers.txt"
        done
    python gerritdm -l 20 < "${TEMPDIR}/gerrit-reviewers.txt" > "${TEMPDIR}/gerrit-stats.txt"

fi

cd ${BASEDIR}
rm -rf ${RELEASE} && mkdir ${RELEASE}
mv ${TEMPDIR}/*stats.txt ${RELEASE}
[ "$REMOVE_TEMPDIR" = "y" ] && rm -rf ${TEMPDIR} || echo "Not removing ${TEMPDIR}"
