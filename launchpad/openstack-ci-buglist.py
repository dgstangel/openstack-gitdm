# List all bugs marked as 'Fix Released' for the specified openstack-ci release
# 
# Note: 
# The openstack-ci Launchpad project categorizes bugs differently from 
# the other openstack projects:  It uses the 'milestone' to denote the 
# major openstack release (i.e. 'folsom', 'grizzly', etc), and the series 
# name is always 'trunk'.
# (whereas with all the other openstack projects, 'series' is the major 
# release, and the milestone is either not used or is irrelevant to us)

import argparse
parser = argparse.ArgumentParser(description='List fixed bugs for an openstack-ci milestone')

parser.add_argument('milestone', help='the milestone to list fixed bugs for')
args = parser.parse_args()

from launchpadlib.launchpad import Launchpad

launchpad = Launchpad.login_with('openstack-dm', 'production')

# look only at the openstack-ci project
project = launchpad.projects['openstack-ci']

# for openstack-ci the series is always 'trunk' (unlike other core projects
# where the series is the major release, like 'folsom', 'grizzly', etc..)
series = project.getSeries(name='trunk')

for milestone in series.all_milestones:
    # for each milestone, examine its bugs only if it matches 
    # the release we're looking for
    if milestone.name == args.milestone:
        for task in milestone.searchTasks(status='Fix Released'):
            assignee = task.assignee.name if task.assignee else '<unknown>'
            # we have to get a little more creative about finding dates for some of these ci bugs
            date = task.date_fix_committed or task.date_fix_released or task.date_closed or task.date_created
            print task.bug.id, assignee, date.date()
