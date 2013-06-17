#!/bin/bash
# 
# This bootstrap script uses puppet to setup a
#  LAMP platform appropriate for Drupal
#
# assumes the following bash vars are defined:
#
#  - PUPPET_REPO_URL
#  - PUPPET_REPO_BRANCH
#
#  - DRUPAL_REPO_URL
#  - DRUPAL_REPO_BRANCH
#  - APP_REPO_URL=
#  - APP_REPO_BRANCH
#
#  - EXTRA_PKGS (optional)

#
# Starting from the Drupal install, here's what I did:
#
# * Modified huit_website.sql mysqldump to remove the INSERT statements for
# the cache tables. When you move a Drupal site, you really don't want to
# bring along the cached data. Plus, I was getting an error during the
# import somewhere around where the cache tables were being INSERTed, so I
# decided to remove the INSERTs.
#
# * scp the huit Drupal profile to the server
# * scp the files.tar.gz to the server
# * scp the database dump to the server
# * scp the sites.tar.gz file to the server
#
# Back on the EC2 instance (from my home directory):
#
# * sudo chown -R root:root huit
# * sudo mv huit /var/www/drupal/profiles/.
#
# * tar -zxf files.tar.gz
# * tar -zxf sites.tar.gz
# * sudo chown -R root:root files
# * sudo chown -R root:root sites
#
# * mysql -u drupal -p drupal < huit_website.sql
#
# * sudo mv /var/www/drupal/sites /var/www/drupal/sites.orig
# * sudo mv sites /var/www/drupal/.
# * sudo cp /var/www/drupal/sites.orig/default/settings.php
#           /var/www/drupal/sites/default/.
# * sudo mv files /var/www/drupal/sites/default/.
# 
# And then it worked! There's probably a more straightforward way of doing
# this, but that's what I have for now. If you want to have a look, I'll
# keep this instance going for a while:
# http://ec2-54-225-18-203.compute-1.amazonaws.com/. I noticed Varnish is
# enabled, but it doesn't appear to be serving cached pages. I'm going to
# take a look at that next.
#
# -------------------
#
# I changed a few more things to get Varnish working properly (and to fix
# errors related to the files directory *not* vein world-writable):
#
# * sudo chmod -R 777 /var/www/drupal/sites/default/files
#
# * Turned on Drupal caching and set maximum lifetime to a non-zero amount
#   (at admin/config/development/performance)
#
# * Un-comented this line:
#   $conf['reverse_proxy'] = TRUE;
#
# And this line:
#
#  #$conf['reverse_proxy_addresses'] = array('a.b.c.d', ...);
#
#  and changed it to:
#
#  $conf['reverse_proxy_addresses'] = array('127.0.0.1');
#
# After I did the above, Drupal stopped complaining about the files
# directory *and* anonymous users started seeing Varnish hits.
#
# I think that does it.
#
# I hope that all makes sense, and I think this instance now looks good.
# Next steps are probably to connect up an RDS for the database and an S3
# bucket for the files directory. But this is a great start.
#
# Let me know if you have any questions on this stuff, and let me know if
# you want to talk about moving the other things forward. I probably won't
# have much time to pour into this until after July 4, but we can try.
#

# These are pretty much defaults from various puppet modules.
DB_NAME=drupal
DB_USERNAME=drupal
DB_PWD=drupal
DB_ROOT_USERNAME=root
DB_ROOT_PWD=password
DB_HOST=localhost
DB_URL=mysql://${DB_USERNAME}:${DB_PWD}@${DB_HOST}/${DB_NAME}

DRUPAL_ROOT=/var/www/drupal/


#---------------------------------
#  Build and configure PLATFORM
#---------------------------------

prepare_rhel6_for_puppet ${EXTRA_PKGS}

#
# pull, setup and run puppet manifests
#

cd /tmp 
git_pull ${PUPPET_REPO_URL} ${PUPPET_REPO_BRANCH}
puppet apply ./manifests/site.pp --modulepath=./modules

#*********************************
# Define a set of functions to do 
#  various aspects of building a 
#  Drupal site
#******************************

setup_drush() {
	
	# FIXME: Add in DRUSH using "pear" until puppet modules are better
	pear channel-discover pear.drush.org
	pear install drush/drush
}

get_custom_data() {
	
	# Setup the AWS credentials again, since they are 
	#  temporary
	#setup_aws_creds

	local tmpd=$( mktemp -d )
	cd ${tmpd}

	#
	# Pull from provided URLs any private data 
	#  for the application
	#
	pull_private_data $DATA_URLS
		
	echo $tmpd				
}

#
# Installs a generic Drupal instance
# 
install_drupal() {
	
	#
	# Pull and install Drupal 
	#
	local orig_dir=$( pwd )
	mkdir -p ${DRUPAL_ROOT}
	cd ${DRUPAL_ROOT}/; cd ..
	rm -rf drupal*
	
	git_pull ${1} ${2}
	ln -sf $(pwd) ../drupal 

	# Setup the files directory
	mkdir -p  ${DRUPAL_ROOT}/sites/default/files
	chmod 777 ${DRUPAL_ROOT}/sites/default/files -R
	cd ${orig_dir}
}

install_drupal_modules() {
	
	#
	# Add requested drupal modules
	# 
	local orig_dir=$( pwd )
	cd ${DRUPAL_ROOT}
	MODS="${DRUPAL_MODULES}"
	for mod in ${MODS}; do
		drush dl ${mod} -y 
		#drush en ${mod} -y	
	done
	cd ${orig_dir}
}

install_standard_drupal_site() {
	
	# Do a default, standard installation 
	local orig_dir=$( pwd )
	cd ${DRUPAL_ROOT}
	drush si standard \
	 --db-url=${DB_URL} \
	 --db-su=${DB_ROOT_USERNAME} \
	 --db-su-pw=${DB_ROOT_PWD}\
	 --site-name="Drupal Vanilla Dev Site" \
	 -y
	cd ${orig_dir}
}
	
install_custom_drupal_code() {
	
	local orig_dir=$( pwd )
	
	# Capture original sites/ 
	cd ${DRUPAL_ROOT}
	cp -av sites sites.orig	
	cp sites/default/settings.php ${orig_dir}/
	
	# 
	# pull a repo of the application code 
	if ! [ -z "${APP_REPO_URL}" ]; then 
		git_pull ${APP_REPO_URL} ${APP_REPO_BRANCH}
		cp -rf sites profiles ${DRUPAL_ROOT}/
	fi

	# unpack an archive of the application code that was already downloaded
	if ! [ -z "${APP_ARCHIVE_FILE}" ]; then 	
		cd ${DRUPAL_ROOT}
		tar xzf ${tmpd}/${APP_ARCHIVE_FILE}
		cd -
	fi

	# move any old settings.php files out of the way
	mv -f ${DRUPAL_ROOT}/sites/default/settings.php ${DRUPAL_ROOT}/sites/default/settings.php.old
	
	# Fix up modules ... seems that custom modules aren't picked up
	#  by an install?

	#	if [ -d ${DRUPAL_ROOT}/sites/all/custom ]; then
	#	
	#		cd ${DRUPAL_ROOT}/sites/all/modules
	#		mods=$( ls ../custom )
	#		for mod in $mods; do 
	#			ln -s ../custom/${mod} .
	#		done
	#		cd /var/www/drupal
	#		for mod in $mods; do 
	#			drush en ${mod} -y
	#		done				
	#		cd -
	#	fi
	
	chown -R root:root ${DRUPAL_ROOT}
	
	cd ${orig_dir}
}		

#
# Sets up an empty data, loads data if neeeded
#  and clears out any caches
#
setup_site_database() {
	
	local orig_dir=$( pwd )
		
	# this should blow away original database
	drush sql-create -y \
        --db-url={DB_URL} \
        --db-su=${DB_ROOT_USER} \
        --db-su-pw=${DB_ROOT_PWD}
    
    # Database pukes on occasion .. this seems to help.
	# Also see ...http://dev.mysql.com/doc/refman/5.0/en/gone-away.html
	# and look into setting 'max_allowed_packet' variable.

    service mysqld restart
    
	if ! [ -z "${SITE_DATABASE_FILE}" ]; then 
		cat "${SITE_DATABASE_FILE}" | \
		gunzip - | \
		mysql -u ${DB_ROOT_USERNAME} -p${DB_ROOT_PWD} ${DB_NAME} 
	
		# clear out any cache tables
		#drush cache clear --db-url={DB_URL}
		CACHES=$( echo "show tables;" | mysql drupal -ppassword | grep cache )
		for CACHE in $CACHES; do
			echo "delete from ${CACHE};" | mysql -u ${DB_ROOT_USERNAME} -p${DB_ROOT_PWD} ${DB_NAME} 
		done
	fi
	cd ${orig_dir}	
}

install_site_data() {
	
	local orig_dir=$( pwd )
		
	# include user data (assume top level dir is "files/"
	if ! [ -z "${SITE_DATA}" ]; then 

		cd ${DRUPAL_ROOT}/sites/default
		tar xzf ${tmpd}/${SITE_DATA} 2>/dev/null
		cd -
	fi
	
	chmod -R 777 ${DRUPAL_ROOT}/sites/default/files
	cd ${orig_dir}		
}	

configure_settings_php() {
	cp ./settings.php ${DRUPAL_ROOT}/sites/default/
}

configure_varnish_caching() {
	cat >> ${DRUPAL_ROOT}/sites/default/settings.php <<"EOF"                                                                                                                   
$conf['reverse_proxy'] = TRUE;
$conf['reverse_proxy_addresses'] = array('127.0.0.1');
EOF
}

#
# Configure settings.php with proper connection string.
#


#************
#
# MAIN
#
#************

setup_drush
echo "Using drush version from: $( which drush )"

echo "Pulling private website code, files and database ..."
tmpd=$( get_custom_data )
cd ${tmpd}

echo "Installing upstream Drupal code ..."
install_drupal ${DRUPAL_REPO_URL} ${DRUPAL_REPO_BRANCH}

echo "Creating a vanilla Drupal site ..."
install_standard_drupal_site

echo "Installing desired extra modules ... "
install_drupal_modules

# Check for customizations ...
if ! [ -z ${APP_REPO_URL} -a -z ${APP_ARCHIVE_FILE} ]; then

	echo "Installing any custom Drupal Code ..."
	install_custom_drupal_code

	echo "Setting up site database from SQL dump ...."
	setup_site_database

	echo "Copying site files ... "
	install_site_data

	echo "Setup settings.php for this site ..."
	configure_settings_php
fi

# setting up varnish caching ...
configure_varnish_caching

service httpd restart 
service varnish restart 







