import 'dart:async';
import 'dart:convert';
import 'dart:html';

import 'package:angular/angular.dart';
import 'package:quickpin/component/breadcrumbs.dart';
import 'package:quickpin/component/pager.dart';
import 'package:quickpin/component/title.dart';
import 'package:quickpin/rest_api.dart';
import 'package:quickpin/sse.dart';

/// A controller for searching through profiles and sites.
@Component(
    selector: 'search',
    templateUrl: 'packages/quickpin/component/search.html',
    useShadowDom: false
)
class SearchComponent {
    Map backgroundTask;
    List<Breadcrumb> crumbs;
    int currentPage;
    String error = '';
    bool loading = false;
    Map allFacets, facets, topFacets;
    List facetNames = [
        'type_s',
        'site_name_txt_en',
        'username_s',
        'post_date_tdt',
        'join_date_tdt',
        'is_stub_b',
    ];
    Map facetHumanNames = {
        'join_date_tdt': 'Joined Date',
        'post_date_tdt': 'Post Date',
        'username_s': 'Profile Name',
        'site_name_txt_en': 'Site Name',
        'type_s': 'Type',
        'is_stub_b': 'Profile Stub',
    };
    Map facetHumanValues = {
        'Profile': 'Profile',
        'Post': 'Post',
    };
    int selectedFacetCount = 0;
    Map<String, Map> selectedFacets;
    Pager pager;
    String query;
    List results;
    int resultsPerPage = 10;
    String sort, sortDescription;
    List<String> urls;

    final RestApiController _api;
    final RouteProvider _rp;
    final Router _router;
    final SseController _sse;
    final TitleService _ts;

    /// Constructor
    SearchComponent(this._api, this._rp, this._router, this._sse, this._ts) {
        // Get the current query parameters from URL...
        var route = this._rp.route;
        this._parseQueryParameters(route.queryParameters);

        if (this.query != null) {
            this._fetchSearchResults();
        }

        // ...and pay attention to new parameters announced in the URL.
        // Add event listeners...
        RouteHandle rh = route.newHandle();
        List<StreamSubscription> listeners = [
            rh.onEnter.listen(this._routeListener),
            this._sse.onWorker.listen(this._workerListener),
        ];

        // ...and remove event listeners when we leave this route.
        rh.onLeave.take(1).listen((e) {
            listeners.forEach((listener) => listener.cancel());
        });
    }
    /// Handle the selection of a facet.
    void handleFacet(event, facetName) {
        if (event.target.checked) {
            this.selectedFacets[facetName][event.target.value] = true;
            this.selectedFacetCount++;
        } else {
            this.selectedFacets[facetName].remove(event.target.value);
            this.selectedFacetCount--;
        }

        Map args = this._makeUrlArgs();
        args.remove('page');
        this._router.go('search',
                        this._rp.route.parameters,
                        queryParameters: args);
    }

    /// Handle a click on the search button.
    void handleSearchButton() {
        Map args = this._makeUrlArgs();
        args.remove('page');
        args.remove('facets');
        this._router.go('search',
                        this._rp.route.parameters,
                        queryParameters: args);
    }

    /// Handle a keypress in the search input field.
    void handleSearchKeypress(event) {
        if (event.keyCode == KeyCode.ENTER) {
            this.handleSearchButton();
        }
    }

    /// Sort by a specified field.
    void sortBy(String sort) {
        Map args = this._makeUrlArgs();
        args.remove('page');

        if (sort == null) {
            args.remove('sort');
        } else {
            args['sort'] = sort;
        }

        this._router.go('search',
                        this._rp.route.parameters,
                        queryParameters: args);
    }

    /// Get search results from the API.
    void _fetchSearchResults() {
        this.loading = true;
        Map urlArgs = this._makeUrlArgs();

        this._api
            .get('/api/search/', urlArgs: urlArgs, needsAuth: true)
            .then((response) {
                this.allFacets = response.data['facets'];
                this._makeTopFacets();
                this.results = response.data['results'];

                if (this.results.length == 0) {
                    this.error = 'No records match your query.';
                }

                this.pager = new Pager(response.data['total_count'],
                                       this.currentPage,
                                       resultsPerPage:this.resultsPerPage);
            })
            .catchError((response) {
                this.error = response.data['message'];
            })
            .whenComplete(() {this.loading = false;});
    }

    /// Get a query parameter as an int.
    void _getQPInt(value, [defaultValue]) {
        if (value != null) {
            return int.parse(value);
        } else {
            return defaultValue;
        }
    }

    /// Get a query parameter as a string.
    void _getQPString(value, [defaultValue]) {
        if (value != null) {
            return Uri.decodeComponent(value);
        } else {
            return defaultValue;
        }
    }

    /// Find the top N facets in each facet category.
    Map _makeTopFacets() {
        const int N = 10;
        this.facets = new Map();
        this.topFacets = new Map();

        this.allFacets.forEach((k,v) {
            if (v.length <= N) {
                this.topFacets[k] = v;
            } else {
                var sorted = new List.from(v);

                // Sort descending by count and take top N facets.
                sorted.sort((a,b) => b[1] - a[1]);
                sorted.removeRange(N, sorted.length);

                // Sort alpha by facet value.
                sorted.sort((a,b) => a[0].compareTo(b[0]));
                this.topFacets[k] = sorted;
            }

            this.facets[k] = this.topFacets[k];
        });

        return topFacets;
    }

    /// Make a map of arguments for a URL query string.
    void _makeUrlArgs() {
        var args = new Map<String>();

        // Create query, page, and sort URL args.
        if (this.currentPage != 1) {
            args['page'] = this.currentPage.toString();
        }

        if (this.query != null && !this.query.trim().isEmpty) {
            args['query'] = this.query;
        }

        if (this.resultsPerPage != 10) {
            args['rpp'] = this.resultsPerPage.toString();
        }

        if (this.sort != null) {
            args['sort'] = this.sort;
        }

        // Create facet URL args.
        var facetArgs = new List<String>();

        this.selectedFacets.forEach((facetName, facetValues) {
            facetValues.forEach((facetValue, selected) {
                if (selected) {
                    facetArgs.add(facetName);
                    facetArgs.add(facetValue);
                }
            });
        });

        if (facetArgs.length > 0) {
            args['facets'] = facetArgs.join("\x00");
        }

        return args;
    }

    /// Take a map of query parameters and parse/load into member variables.
    void _parseQueryParameters(qp) {
        this.error = '';

        // Set up query and paging URL args.
        this.currentPage = this._getQPInt(qp['page'], 1);
        this.query = this._getQPString(qp['query']);
        this.resultsPerPage = this._getQPInt(qp['rpp'], 10);

        // Parse facet URL args.
        this.selectedFacets = {
            'join_date_tdt': {},
            'post_date_tdt': {},
            'site_name_txt_en': {},
            'type_s': {},
            'username_s': {},
            'is_stub_b': {},
        };

        this.selectedFacetCount = 0;

        if (qp['facets'] != null) {
            List<String> facetList = this._getQPString(qp['facets']).split("\x00");

            for (int i = 0; i < facetList.length; i += 2) {
                String key = facetList[i];
                String value = facetList[i+1];
                this.selectedFacets[key][value] = true;
                this.selectedFacetCount++;
            }
        }

        // Set up breadcrumbs.
        if (this.query == null) {
            this.crumbs = [
                new Breadcrumb('QuickPin', '/'),
                new Breadcrumb('Search'),
            ];
            this._ts.title = 'Search';
        } else {
            this.crumbs = [
                new Breadcrumb('QuickPin', '/'),
                new Breadcrumb('Search', '/search'),
                new Breadcrumb('"' + this.query + '"'),
            ];
            this._ts.title = 'Search "${this.query}"';
        }

        // Set up sort orders.
        this.sort = this._getQPString(qp['sort']);

        Map sortDescriptions = {
            'post_date_tdt': 'Post Date (Old→New)',
            '-post_date_tdt': 'Post Date (New→Old)',
            'username_s': 'Username (A→Z)',
            '-username_s': 'Username (Z→A)',
        };

        if (sortDescriptions.containsKey(this.sort)) {
            this.sortDescription = sortDescriptions[this.sort];
        } else {
            this.sortDescription = 'Most Relevant';
        }
    }

    /// Listen for changes in route parameters.
    void _routeListener(Event e) {
        this._parseQueryParameters(e.queryParameters);

        if (this.query == null || this.query.trim().isEmpty) {
            this.results = new List();
        } else {
            this._fetchSearchResults();
        }
    }

    /// Listen for updates from background workers.
    void _workerListener(Event e) {
        Map job = JSON.decode(e.data);

        if (this.backgroundTask == null && job['queue'] == 'index' &&
            (job['status'] == 'started' || job['status'] == 'progress')) {

            job['Description'] = '(Loading Description...)';
            this.backgroundTask = job;

            this._api
                .get('/api/tasks/job/${job["id"]}', needsAuth: true)
                .then((response) {
                    String description = response.data['description'];
                    this.backgroundTask['description'] = description;
                });
        } else if (this.backgroundTask['id'] == job['id']) {
            if (job['status'] == 'progress') {
                this.backgroundTask['progress'] = job['progress'];
            } else if (job['status'] == 'finished') {
                this.backgroundTask = null;
            }
        }
    }
}
