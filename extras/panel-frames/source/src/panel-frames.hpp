#pragma once
#include <QColor>
#include <QFrame>
#include <QGridLayout>
#include <QPointer>
#include <QTimer>
#include <QVariant>
#include <QVBoxLayout>
#include <QWidget>
#include <vector>

class PanelFrames final : public QObject {
public:
    explicit PanelFrames(QWidget *mainWindow);
    ~PanelFrames() override;
    void refresh();
    void restore();
    int panelCount() const;

protected:
    bool eventFilter(QObject *object, QEvent *event) override;

private:
    struct Panel {
        QPointer<QWidget> host;
        QPointer<QWidget> display;
        QPointer<QFrame> frame;
        QPointer<QGridLayout> grid;
        QPointer<QVBoxLayout> box;
        QSpacerItem *spacer = nullptr;
        QMargins originalMargins;
        int originalRowHeight = 0;
    };
    static constexpr int inset = 12;
    static constexpr int mainTopInset = 8;
    struct Title {
        QPointer<QWidget> widget;
        QVariant previousInsetProperty;
    };
    QPointer<QWidget> main;
    bool mainInsetApplied = false;
    std::vector<Title> titles;
    std::vector<Panel> panels;
    QTimer refreshTimer;
    QTimer geometryTimer;
    void reconcile();
    bool addPanel(QWidget *host, QWidget *display, bool preview);
    void updateFrames();
    void refreshColor(QWidget *display);
    void updateMainInset(bool enabled, QWidget *canvas = nullptr);
    static void refreshTitleStyle(QWidget *title);
};
