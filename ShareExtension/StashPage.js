// Runs in the shared Safari page. Returns the page URL, title and any directly playable videos.
var StashPage = function() {};
StashPage.prototype = {
    run: function(args) {
        var media = [];
        function add(value) {
            if (!value) { return; }
            try {
                var url = new URL(value, document.baseURI).href;
                if (url.indexOf("http") !== 0) { return; }
                if (/\.(m3u8|mpd)(\?|$)/i.test(url)) { return; }
                if (media.indexOf(url) < 0) { media.push(url); }
            } catch (e) {}
        }
        var videos = Array.prototype.slice.call(document.querySelectorAll("video"));
        // The video being watched (largest on screen) first.
        videos.sort(function(a, b) {
            return (b.clientWidth * b.clientHeight) - (a.clientWidth * a.clientHeight);
        });
        videos.forEach(function(video) {
            add(video.currentSrc || video.src);
            Array.prototype.forEach.call(video.querySelectorAll("source"), function(source) { add(source.src); });
        });
        var metas = document.querySelectorAll('meta[property="og:video:secure_url"],meta[property="og:video:url"],meta[property="og:video"],meta[name="twitter:player:stream"]');
        Array.prototype.forEach.call(metas, function(meta) { add(meta.content); });
        var title = document.title;
        var ogTitle = document.querySelector('meta[property="og:title"]');
        if (ogTitle && ogTitle.content) { title = ogTitle.content; }
        args.completionFunction({ "url": document.URL, "title": title, "media": media });
    },
    finalize: function(args) {}
};
var ExtensionPreprocessingJS = new StashPage;
