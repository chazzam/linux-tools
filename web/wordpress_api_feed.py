#! /usr/bin/env python3

#~ # Requires:
#~ #   Beautiful Soup 4, html5lib, PyExecJS, nodejs
# Requires:
#     cfscrape   https://github.com/Anorov/cloudflare-scrape
#     feedgen    https://github.com/lkiesow/python-feedgen
#     requests   http://docs.python-requests.org/en/master/
#   sudo -H pip install cfscrape feedgen requests
"""
Parse out a wordpress api for pages, and convert selected items into an
RSS or Atom feed
"""
import sys
import argparse
import configparser
import logging
import os
import os.path
import re

#~ import bs4
import cfscrape
import feedgen
import requests
# feedgen: https://github.com/lkiesow/python-feedgen/blob/master/readme.rst
#~ import lxml
#~ from lxml import html, etree
#~ from bs4 import BeautifulSoup, UnicodeDammit

## TODO:Need to search the link= for patreon, and the body for Ji Ning...


# Need to get username and password:
## 1. from command-line args
## 2. from ~/.wordpress-api-rss.conf (or specified conf file)
## 3. if have user, but not password, prompt for password with no screen echo
## 4. error, mention args for user/pass and ~/.wordpress-api-rss.conf


# pull in existing feed file if it exists
# login to wordpress site
# connect to API/pages?per_page=per_page_value&page=1
# scan until hit max_page_entries
# NOTE: by scanning forward, we might miss some new thing now, but at
# worst we get duplicates this read, and pull those new things next time.
## will need to periodically request a new ?per_page=per_page_value&page=N+1
## of the API once we consume all currently available entries
## Check if the current page already in the list (from existing rss feed import.) page-id@epoch-time
### if it is, pop the current one out, then append the new one. (It may have been updated)
## process up to pages?per_page=per_page_value&page=ceil((max_page_entries + 1)/ per_page_value)
# build rss feed on disk up to max_rss_entries, overwrite every run. (write newest first)
## only include in rss if it matches the search term (match all if search is empty)
# Try really hard to keep going on a failure, and just report it and log the failure

def existing_dir(value):
    """verify argument is or references an existing directory.
    One of these conditions must be met:
        the entire value must reference an existing directory
        the dirname(value) must reference an existing directory
        or the current directory is referenced (only a filename given)
    Intended supported examples:
        /tmp/butterworth.txt - Pass
        /tmp                 - Pass
        butterworth.txt      - Pass
        /non/existing/path/  - Fail
    Args:
        value: string path reference
    Returns:
        value: absolute, real, expanded string path reference
    Raises:
        ArgumentTypeError: If the path cannot be determined to consist of
            already existing directories, and optionally a filename that may or
            may not exist
    """
    try:
        safe_value = os.path.realpath(
            os.path.abspath(
                os.path.expandvars(
                    os.path.expanduser(value))))
    except TypeError:
        safe_value = ''
    dir_name = os.path.dirname(safe_value)
    is_dir = os.path.isdir(safe_value) or os.path.isdir(dir_name)
    if value is None or safe_value == '' or not is_dir:
        argparse.ArgumentTypeError(
            'Must specify an existing directory for input/output')
    return safe_value

def download_chapter():
    """temp def"""
    # Download a given chapter
    #~ if url is None or filename is None:
        #~ return False

    #~ if scraper is not None:
        #~ page = scraper.get(url)
    #~ else:
        #~ page = requests.get(url)
    #~ if page.status_code == 404:
        #~ return False
    #~ page.encoding = 'utf-8'
    pass

def get_options(argv=None):
    """parse the commandline options.
    Check for all supported flags and do any available pre-processing
    """
    default_config = os.path.expanduser("~/.wordpress-api-feed.conf")
    opts = argparse.ArgumentParser(
        description='Parse wordpress pages API into RSS/ATOM feed')

    opts.add_argument(
        '--config', '-c', default=default_config,
        help='Specify config file for wordpress api feed')
    opts.add_argument(
        '--feed_output', '-o', type=existing_dir,
        help='output directory and/or file')
    opts.add_argument(
        '--username', '-u', default='',
        help='Wordpress Username')
    opts.add_argument(
        '--password', '-p', default='',
        help='Wordpress Password (Warning: clear text)')
    opts.add_argument(
        '--site', '-s', default='',
        help='Wordpress Site (e.g. https://wordpress.org)')
    opts.add_argument(
        '--log-level', '-l', default='warning',
        choices=['critical', 'error', 'warning', 'info', 'debug', 'notset'],
        help='Set logging level [warning]')
    opts.add_argument(
        '--options', '-O', nargs='*',
        help='Specify additional config file options [max_item_age_days=15 max_pages=100]')

    logging.debug('Parsing argv: %s', argv)
    args = opts.parse_args(argv)
    logging.debug('Parsed command-line args: %s', args)
    return args

def update_options_with_args(options, args):
    """Update options from command-line args"""
    for key, val in vars(args):
        logging.debug('Looping command-line args: "%s=%s"', key, val)
        if key not in options or val is None or val == '':
            continue
        if isinstance(options[key], int):
            try:
                val = int(val)
            except TypeError:
                logging.warning('Skipping invalid option: "%s=%s"', key, val)
                continue
        logging.debug('Updating options: "%s=%s"', key, val)
        options[key] = val

    # Pull in any extra config file options from args
    if 'options' not in args or not args.options:
        return
    index = -1
    while index <= len(args.options):
        logging.debug('Looping extended command-line args: "%s"', args.options[index])
        # Skip updating this option if command-line is blank
        index += 1
        if args.options[index] == '':
            continue
        opt = args.options[index].split('=', 1)
        if len(opt) != 2:
            # If not in format 'option=value' assume in format 'option value'
            index += 1
            # Handle edge case of last element in list
            if index > len(args.options):
                break
            # Store the next element as our value
            opt.append(args.options[index])

        logging.debug('Detected extended command-line arg: "%s=%s"', opt[0], opt[1])
        if opt[0] not in options or opt[1] == '':
            continue
        if isinstance(options[opt[0]], int):
            try:
                opt[1] = int(opt[1])
            except TypeError:
                logging.warning('Skipping invalid option: %s=%s', opt[0], opt[1])
                continue
        logging.debug('Updating options: "%s=%s"', opt[0], opt[1])
        options[opt[0]] = opt[1]

def update_options_with_config(options, config):
    """Update options from config file"""
    # check for 'sites' section
    # loop over items in config['sites'] as site
    # if site does not exist as a section, continue
    # loop over items in site as key,val
    # if key not in options or val is '', continue
    # if isinstance(options[key], int), val=int(val)
    # options[key] = val
    if 'sites' not in config:
        logging.debug('Asked to update with config, but no sites')
        return
    for site in config['sites']:
        logging.debug('Looping sites, currently: "%s=%s"', site, config['sites'][site])
        # Skip a site if it isn't set to a recognized True value
        try:
            if not config.getboolean('sites', site):
                continue
        except ValueError:
            continue
        # process the site
        for key, val in config[site]:
            logging.debug('Looping config site options: "%s=%s"', key, val)
            if key not in options or val == '':
                continue
            if isinstance(options[key], int):
                try:
                    val = int(val)
                except TypeError:
                    logging.warning('Skipping invalid option: %s=%s', key, val)
                    continue
            logging.debug('Updating options: "%s=%s"', key, val)
            options[key] = val

def process_site(options):
    """Parse site into feed"""
    if not options.site:
        logging.error('No wordpress site specified, try --site [https://wordpress.org]')
        return 1
    if not options.password:
        # Need to prompt for password for options.site, securely
        pass
    return 0


def main(argv=None):
    """Main program control"""
    top_options = {
        'api_pages': 'pages',
        'feed_output': os.path.expanduser('~/wordpress-api-feed-output.xml'),
        'feed_type': 'rss',
        'max_pages': 100,
        'max_feed_items': 0,
        'max_item_age_days': 15,
        'password': '',
        'per_page': 20,
        'search': '',
        'username': '',
        'wordpress_api': 'wp-json/wp/v2',
        'wordpress_login': 'wp-login.php',
        'wordpress_site': ''}
    # Builds: %(wordpress_site)s/%(wordpress_api)s/%(api_pages)s?per_page=%(per_page)s&page=N
    # Defaults: {}
    # Parse Args, get config file
    # Config: loop over [sites], loop each section, for key in Defaults: update_defaults
    # Args: loop, for key in Defaults: update_defaults
    # if no password, or blank, prompt for password, then update_defaults.
    if argv is None:
        argv = sys.argv
    args = get_options(argv[1:])

    # Pull out the log level and setup the logger
    logging.basicConfig(
        filename=os.path.expanduser('~/wordpress-api-feed.log'),
        format='%(asctime)s %(Levelname)s#:%(message)s',
        level=args.log_level.upper())
    #~ logging.basicConfig(filename='/tmp/wordpress-api-feed.log')

    # Log some debug!
    logging.debug('Default Options:\n%s', top_options)
    logging.debug('Accepted argv: "%s"', argv)
    logging.debug('Parsed args: "%s"', args)

    config = configparser.SafeConfigParser()
    # This appears to return an empty config on invalid/non-existent files
    config.read(args.config)
    # Handle no (valid) config
    if 'sites' not in config.sections():
        logging.warning('No sites detected in config file')
        # Process single site, with any command-line args given
        update_options_with_args(top_options, args)
        logging.debug(
            'Processing single site %s with options: %s',
            top_options['site'],
            top_options)
        status = process_site(top_options)
        if status != 0:
            logging.error('Single site %s failed to process: %s',
                          top_options['site'],
                          status)
        return status

    # Process all sites found in config file
    for site in config['sites']:
        site_options = top_options.copy()
        #  update site_options with site config
        update_options_with_config(site_options, config)
        # Update site_options from command-line args
        update_options_with_args(site_options, args)
        logging.debug('Processing site %s with options: %s', site, site_options)
        #  process site into output
        status = process_site(site_options)
        if status != 0:
            logging.warning(
                'Site %s failed to process, return code %s',
                site,
                status)
    #~ scraper = cfscrape.create_scraper()

if __name__ == '__main__':
    # print(flush=True) requires python 3.3+
    # Usage of configparser assumes python 3.2+
    # logging.basicConfig(level=[A-Z]+) requires python 3.2+
    if sys.hexversion < 0x03030000:
        print(
            '\n\nERROR: Requires Python 3.3.0 or newer\n',
            file=sys.stderr,
            flush=True)
        sys.exit(1)
    sys.exit(main())
